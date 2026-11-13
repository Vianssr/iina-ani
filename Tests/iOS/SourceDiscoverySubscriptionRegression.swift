import SourceCore
import SourceRuntime
import Foundation

private actor DynamicChoiceTransport {
    private(set) var apiCalls = 0
    private var includeBackup = true
    func removeBackup() { includeBackup = false }
    func fetch(_ request: URLRequest) throws -> SourceHTTPResponse {
        guard let url = request.url, url.host == "senfun.in" else { throw MobileSourceError.invalidSelection }
        let body: String
        if url.path == "/voddetail/42.html" {
            body = "<div class='module-info-heading'><h1>Dynamic fixture</h1></div><div class='module-play-list-content'><a href='/vodwatch/42/ep_A.html'>Episode 1</a><a href='/vodwatch/42/ep_B.html'>Episode 2</a></div>"
        } else if url.path.hasPrefix("/_senfun_plays/42/") {
            apiCalls += 1
            let episode = url.lastPathComponent == "ep_A" ? "one" : "two"
            let backup = includeBackup ? ",{\"src_site\":\"backup\",\"play_data\":\"https://media.example/\(episode)-backup.m3u8\"}" : ""
            body = "{\"video_plays\":[{\"src_site\":\"direct\",\"play_data\":\"https://media.example/\(episode)-direct.m3u8\"}\(backup)]}"
        } else { throw MobileSourceError.invalidSelection }
        return SourceHTTPResponse(data: Data(body.utf8), url: url, statusCode: 200)
    }
}

private actor DiscoverySearchGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private var held = true
    let search: Data
    let catalog: Data
    let player: Data
    var waiting: Bool { continuation != nil }
    init(search: Data, catalog: Data, player: Data) { self.search = search; self.catalog = catalog; self.player = player }
    func release() { continuation?.resume(returning: search); continuation = nil }
    func fetch(_ url: URL) async -> Data {
        if url.path.contains("search") {
            if held { held = false; return await withCheckedContinuation { continuation = $0 } }
            return search
        }
        return url.path.contains("detail") ? catalog : player
    }
}

@MainActor enum SourceDiscoverySubscriptionRegression {
    static func run(root: URL) async throws {
        let config = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let anime = Anime(id: 991, name: "Trust Fixture Season 2", name_cn: nil, images: nil, summary: nil, date: "2025-01-01", rating: nil, platform: "TV")
        let requested = CatalogEpisode(id: 992, type: 0, sort: 2, ep: 2, name: "Second", name_cn: nil, airdate: nil)
        let title = "Trust Fixture Season 2 TV 2025"
        func search(_ titles: [String]) -> Data {
            Data(titles.enumerated().map { index, title in
                "<div class='module-card-item-info'><div class='module-card-item-title'><a href='/index.php/vod/detail/id/\(42 + index).html'>\(title)</a></div></div>"
            }.joined().utf8)
        }
        func catalog(_ id: String, number: Int = 2, line: Int = 1) -> Data {
            Data("<div class='module-info-heading'><h1>\(title)</h1></div><div class='module-tab-item tab-item'><span>Line A</span></div><div class='module-play-list'><a class='module-play-list-link' href='/index.php/vod/play/id/\(id)/sid/\(line)/nid/\(number).html'>Episode \(number)</a></div>".utf8)
        }
        let player = Data(#"<script>var player_aaaa={"id":"42","sid":1,"nid":2,"points":0,"trysee":0,"encrypt":0,"url":"https://media.example.test/episode.mp4"};</script>"#.utf8)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MobileLibrary(file: directory.appendingPathComponent("Library/favorites.json"),
            libraryFile: directory.appendingPathComponent("Library/library.json"))
        let sourceLibrary = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"), bundled: { [.configured(config)] })
        var enabled = true
        var revision = config.configurationRevision
        let authority: (String) throws -> String = { _ in
            guard enabled else { throw PlaybackFailure.sourceDisabled }
            return revision
        }
        func client(titles: [String], missing: Bool = false) -> MobileSourceClient {
            let searchBody = search(titles)
            let firstCatalog = catalog("42", number: missing ? 1 : 2)
            let secondCatalog = catalog("43", number: missing ? 1 : 2)
            return sourceClient(config) { url in
                if url.path.contains("search") { return searchBody }
                if url.path.contains("detail") { return url.path.contains("43") ? secondCatalog : firstCatalog }
                return player
            }
        }
        let discovery = MobileSourceDiscovery()
        discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources, library: library, authority: authority, client: { _ in client(titles: [title]) })
        while discovery.busy { await Task.yield() }
        precondition(discovery.automatic != nil && discovery.candidates.count == 1)
        let automatic = discovery.automatic!
        let disabled = MobileSourceEntry(source: .native("girigiri"), imported: false)
        discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources + [disabled],
            library: library, authority: { id in
                guard id == config.id else { throw PlaybackFailure.sourceDisabled }
                return try authority(id)
            }, client: { entry in
                precondition(entry.id == config.id, "Initially disabled sources must not send requests")
                return client(titles: [title])
            })
        while discovery.busy { await Task.yield() }
        precondition(discovery.automatic?.id == automatic.id && discovery.failures.isEmpty,
                     "An unrelated initially disabled source must not veto the unique trusted candidate")

        // A participating source with no matches must still revoke uniqueness if
        // it is disabled while another source is completing its search.
        var emptyObject = try JSONSerialization.jsonObject(with: config.encodedData()) as! [String: Any]
        emptyObject["id"] = "a-empty-search"
        let emptyConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: emptyObject))
        let emptyEntry = MobileSourceEntry(source: .configured(emptyConfig), imported: true)
        var emptyEnabled = true
        let participationGate = DiscoverySearchGate(search: search([title]), catalog: catalog("42"), player: player)
        discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources + [emptyEntry],
            library: library, authority: { id in
                if id == emptyConfig.id {
                    guard emptyEnabled else { throw PlaybackFailure.sourceDisabled }
                    return emptyConfig.configurationRevision
                }
                return try authority(id)
            }, client: { entry in
                if entry.id == emptyConfig.id { return sourceClient(emptyConfig) { _ in Data() } }
                return sourceClient(config) { await participationGate.fetch($0) }
            })
        while !(await participationGate.waiting) { await Task.yield() }
        emptyEnabled = false
        await participationGate.release()
        while discovery.busy { await Task.yield() }
        precondition(discovery.candidates.count == 1 && discovery.automatic == nil &&
                     discovery.failures.contains(.sourceDisabled),
                     "A source disabled after participating must still block automatic handoff")
        let flow = MobileSourceFlow(client: client(titles: [title]), requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(requested.id, type: 0, sort: 2), library: library, authority: { try authority(config.id) })
        flow.acceptCandidate(automatic, automatically: true)
        await SourceRegression.idle(flow)
        precondition(flow.takeResolved()?.context.episode == .bangumi(requested.id, type: 0, sort: 2))
        precondition(library.storedMapping(for: .bangumi(anime.id), episode: .bangumi(requested.id, type: 0, sort: 2)) != nil)
        let savedFlow = MobileSourceFlow(client: client(titles: [title]), requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(requested.id, type: 0, sort: 2), library: library, authority: { try authority(config.id) })
        savedFlow.playSaved()
        await SourceRegression.idle(savedFlow)
        precondition(savedFlow.resolved != nil)
        try library.invalidateMapping(for: .bangumi(anime.id), episode: .bangumi(requested.id, type: 0, sort: 2), failure: .missingEpisode)
        precondition(savedFlow.takeResolved() == nil && savedFlow.requiresReconfirmation)
        discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources, library: library, authority: authority, client: { _ in client(titles: [title]) })
        precondition(!discovery.busy && discovery.automatic == nil) // Invalid saved choice is never bypassed.
        try library.removeMapping(for: .bangumi(anime.id), episode: .bangumi(requested.id, type: 0, sort: 2))
        for (titles, missing) in [([title, title], false), (["Trust Fixture Season 3 TV 2025"], false), ([title], true), (["Trust Fixture Season 2"], false)] {
            discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources, library: library, authority: authority, client: { _ in client(titles: titles, missing: missing) })
            while discovery.busy { await Task.yield() }
            precondition(discovery.automatic == nil)
        }
        enabled = false
        discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources, library: library, authority: authority, client: { _ in fatalError("Disabled source sent a request") })
        while discovery.busy { await Task.yield() }
        precondition(discovery.automatic == nil)
        enabled = true
        for change in [0, 1, 2] {
            let gate = DiscoverySearchGate(search: search([title]), catalog: catalog("42"), player: player)
            discovery.find(anime: anime, episode: requested, sources: sourceLibrary.sources, library: library, authority: authority,
                client: { _ in sourceClient(config) { await gate.fetch($0) } })
            while !(await gate.waiting) { await Task.yield() }
            if change == 0 { discovery.cancel() }
            else if change == 1 { enabled = false }
            else { revision = "changed" }
            await gate.release()
            while discovery.busy { await Task.yield() }
            for _ in 0..<10 { await Task.yield() }
            precondition(discovery.automatic == nil)
            enabled = true; revision = config.configurationRevision
        }
        // A trusted issued candidate must still honor disabled/config-changed authority at handoff.
        let blocked = MobileSourceFlow(client: client(titles: [title]), requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(requested.id, type: 0, sort: 2), library: library, authority: { try authority(config.id) })
        enabled = false; blocked.acceptCandidate(automatic, automatically: true)
        precondition(blocked.failure == .sourceDisabled && blocked.takeResolved() == nil)
        enabled = true

        func subscription(selector: String = "a.subscription-result") throws -> Data {
            let searchURL = config.search!.url.replacingOccurrences(of: "{query}", with: "{keyword}")
            let item: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": ["name": "Audited source", "searchConfig": ["searchUrl": searchURL, "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": selector]]]]
            return try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [item]]])
        }
        let body = try subscription()
        let service = MobileSourceSubscription()
        let originalRevision = sourceLibrary.sources[0].source.configurationRevision
        let originalSearchRevision = sourceLibrary.sources[0].searchRevision
        let searchFetch: SourceHTTPTransport.Fetch = { request in
            SourceHTTPResponse(data: Data("<a class='subscription-result' href='/index.php/vod/detail/id/42.html'>Fixture</a>".utf8),
                               url: request.url!, statusCode: 200)
        }
        service.check(library: sourceLibrary, fetch: { body }, searchFetch: searchFetch)
        while service.busy { await Task.yield() }
        precondition(service.preview?.state.overrides.count == 1)
        let cancelled = service.preview!
        service.cancel()
        do { try service.apply(cancelled, library: sourceLibrary); fatalError("Cancelled preview applied") } catch {}
        service.check(library: sourceLibrary, fetch: { body }, searchFetch: searchFetch)
        while service.busy { await Task.yield() }
        let preview = service.preview!
        let defaults = UserDefaults.standard
        let key = "mobile.sources.fqdm.enabled"
        let old = defaults.object(forKey: key)
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        defaults.set(false, forKey: key)
        try service.apply(preview, library: sourceLibrary)
        precondition(sourceLibrary.sources[0].source.configurationRevision == originalRevision)
        precondition(sourceLibrary.sources[0].searchRevision != originalSearchRevision)
        precondition(!defaults.bool(forKey: key))
        let stateFile = directory.appendingPathComponent("Sources/SearchSubscription/state.json")
        let bytes = try Data(contentsOf: stateFile)
        let reopened = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"), bundled: { [.configured(config)] })
        precondition(reopened.sources[0].source.configurationRevision == originalRevision)
        precondition(reopened.sources[0].searchRevision == sourceLibrary.sources[0].searchRevision)
        let reopenedBytes = try Data(contentsOf: stateFile)
        precondition(reopenedBytes == bytes)
        // Search-only refresh does not invalidate the exact previously confirmed playback selection.
        let oldMappingFlow = MobileSourceFlow(client: client(titles: [title]), requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(requested.id, type: 0, sort: 2), authority: { originalRevision },
            resumeMapping: ConfirmedSourceMapping(context: try client(titles: [title]).playbackContext(automatic.episode!,
                in: automatic.catalog, requestedWork: .bangumi(anime.id),
                requestedEpisode: .bangumi(requested.id, type: 0, sort: 2)), sourceTitle: title))
        oldMappingFlow.updateAccess(enabled: true, configurationRevision: originalRevision)
        precondition(!oldMappingFlow.requiresReconfirmation)
        service.check(library: sourceLibrary, fetch: { body }, searchFetch: searchFetch)
        while service.busy { await Task.yield() }
        let stale = service.preview!
        var changed = try JSONSerialization.jsonObject(with: config.encodedData()) as! [String: Any]
        changed["name"] = "Changed configuration"
        let changedData = try JSONSerialization.data(withJSONObject: changed)
        try sourceLibrary.apply(.init(configuration: SourceConfiguration.load(data: changedData), data: changedData))
        do { try service.apply(stale, library: sourceLibrary); fatalError("Stale preview applied") } catch {}
        let afterStale = try Data(contentsOf: stateFile)
        precondition(afterStale == bytes)
        let failed = try await MobileSourceSubscription.prepare(baselines: reopened.subscriptionBaselines,
            current: [MobileSourceEntry(source: .configured(config), imported: false,
                search: NativeSearchSource(hosts: config.hosts, search: config.search!))],
            fetch: { body }, searchFetch: { _ in throw URLError(.timedOut) })
        precondition(failed.state.overrides.isEmpty)
        let conflict = try JSONSerialization.jsonObject(with: subscription(selector: "a.other")) as! [String: Any]
        let first = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let firstItems = (first["exportedMediaSourceDataList"] as! [String: Any])["mediaSources"] as! [Any]
        let secondItems = (conflict["exportedMediaSourceDataList"] as! [String: Any])["mediaSources"] as! [Any]
        let duplicate = try JSONSerialization.data(withJSONObject: ["mediaSources": firstItems + secondItems])
        let rejected = try SourceSubscriptionConverter.convert(data: duplicate, baselines: reopened.subscriptionBaselines,
            installed: [:], names: ["fqdm": "Tomato Anime"])
        precondition(rejected.overrides.isEmpty)
        try await changedJSONSubscription()
        try await changedStaticSubscription(directory: directory.appendingPathComponent("StaticSearch"))
        try await dynamicPlaybackChoices()
        print("PASS: discovery authority, desktop subscription verification, cancelled/stale previews, search-only revision and enablement preservation")
    }

    private static func changedStaticSubscription(directory: URL) async throws {
        let origin = "https://static-search.example.com"
        let id = "custom-static-search"
        let object: [String: Any] = [
            "id": id, "name": "Imported static search fixture", "version": 4,
            "hosts": ["static-search.example.com"], "mediaHosts": ["media.example.org"],
            "anonymousExternalHTTPSMedia": false,
            "capabilities": ["information", "search", "episodes", "resolve", "mpv"],
            "route": ["pattern": "^/(.*)$", "idGroup": 1, "detailTemplate": origin + "/{id}"],
            "catalog": ["url": origin + "/{id}", "format": "web-selector"],
            "player": ["format": "web-selector", "allowedExtensions": ["mp4"]],
            "search": ["url": origin + "/old-search?q={query}", "format": "html", "queryParameter": "q",
                "pageParameter": "page", "rowsPerPage": 20, "resultsSelector": "a.old-result",
                "titleSelector": "self", "hrefAttribute": "href"],
            "webSelector": ["baseURL": origin, "subjectFormat": "a", "searchNames": "a.old-result",
                "searchLinks": "a.old-result", "channelFormat": "no-channel", "episodeNames": "a.episode",
                "episodeLinks": "a.episode"]]
        let data = try JSONSerialization.data(withJSONObject: object)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("import.json")
        try data.write(to: file)
        let sourcesDirectory = directory.appendingPathComponent("Sources")
        let library = MobileSourceLibrary(directory: sourcesDirectory, bundled: { [] })
        let defaults = UserDefaults.standard
        let key = "mobile.sources." + id + ".enabled"
        let old = defaults.object(forKey: key)
        defer { if let old { defaults.set(old, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try library.apply(library.prepare(file))
        let original = library.sources.first { $0.id == id }!
        precondition(original.imported && original.source.configured?.version == 4)
        let configurationRevision = original.source.configurationRevision
        let item: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": [
            "name": "Updated static search", "searchConfig": [
                "searchUrl": origin + "/new-search?term={keyword}", "subjectFormatId": "a",
                "selectorSubjectFormatA": ["selectLists": "a.new-result"]]]]
        let feed = try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
        let expected = SourceItemRef(sourceID: id, pageURL: origin + "/series/42?season=2", kind: .work)
        let fetch: SourceHTTPTransport.Fetch = { request in
            precondition(request.url?.host == "static-search.example.com")
            precondition(request.url?.path == "/new-search", "Old source search rules must never be requested")
            precondition(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains {
                $0.name == "term" && $0.value == "海贼王"
            } == true)
            precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
            precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
            precondition(!request.httpShouldHandleCookies)
            return SourceHTTPResponse(data: Data("""
                <a class='old-result' href='/series/wrong'>Old selector decoy</a>
                <a class='new-result' href='/series/42?season=2'>Updated fixture</a>
                """.utf8), url: request.url!, statusCode: 200)
        }
        let service = MobileSourceSubscription()
        service.check(library: library, fetch: { feed }, searchFetch: fetch)
        while service.busy { await Task.yield() }
        precondition(service.preview?.state.overrides[id] != nil)
        try service.apply(service.preview!, library: library)
        let installed = library.sources.first { $0.id == id }!
        let reopened = MobileSourceLibrary(directory: sourcesDirectory, bundled: { [] })
        let reloaded = reopened.sources.first { $0.id == id }!
        for entry in [installed, reloaded] {
            precondition(entry.source.configurationRevision == configurationRevision)
            precondition(entry.searchRevision != original.searchRevision)
            let page = try await MobileSourceClient(source: entry.source, search: entry.search, fetch: fetch).search("海贼王")
            precondition(page.works.count == 1 && page.works[0].item == expected)
            precondition(page.works[0].title == "Updated fixture")
        }
        precondition(installed.searchRevision == reloaded.searchRevision)
    }

    private static func changedJSONSubscription() async throws {
        let source = RuntimeSource.native("mutedm")
        let baseline = try SourceSubscriptionBaselines.load()[source.id]!
        let baselines = [source.id: baseline]
        let item: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": [
            "name": "Changed JSON fixture", "searchConfig": [
                "searchUrl": "https://www.2kdm.com/index.php/ajax/suggest?mid=1&wd={keyword}",
                "subjectFormatId": "json-path-indexed",
                "selectorSubjectFormatJsonPathIndexed": [
                    "selectNames": "$.list[*]['name']", "selectLinks": "$.list[*]['id']",
                    "linkTemplate": "/voddetail/{value}.html"]]]]
        let feed = try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
        let plan = try SourceSubscriptionConverter.convert(data: feed, baselines: baselines,
            installed: baselines, names: [source.id: source.name])
        let converted = try JSONDecoder().decode(NativeSearchSource.self, from: plan.overrides[source.id]!)
        precondition(converted.search.url != baseline.search.url, "Fixture must probe a changed rule")
        precondition(converted.search.resultURLTemplate == "/voddetail/{value}.html")
        let expected = SourceItemRef(sourceID: source.id,
            pageURL: "https://www.2kdm.com/voddetail/42.html", kind: .work)
        let response = Data(#"{"list":[{"id":42,"name":"JSON subscription fixture"}],"total":1}"#.utf8)
        let fetch: SourceHTTPTransport.Fetch = { request in
            precondition(request.url?.host == "www.2kdm.com")
            precondition(request.url?.path == "/index.php/ajax/suggest")
            return SourceHTTPResponse(data: response, url: request.url!, statusCode: 200)
        }
        let verified = try await SourceSubscriptionVerifier.verifyChangedSearches(plan,
            baselines: baselines, installed: baselines, item: { id, raw in
                precondition(id == source.id && raw == expected.pageURL)
                let reference = try? source.item(raw)
                precondition(reference == expected, "JSON result must retain its exact reviewed source identity")
                return reference
            }, fetch: fetch)
        precondition(verified.overrides[source.id] == plan.overrides[source.id],
                     "Changed JSON search was rejected despite a valid canonical detail result")
        let invalid = try await SourceSubscriptionVerifier.verifyChangedSearches(plan,
            baselines: baselines, installed: baselines,
            item: { id, raw in
                guard id == source.id else { return nil }
                return try? source.item(raw)
            }, fetch: { request in
                SourceHTTPResponse(data: Data(#"{"list":[{"id":"not-an-id","name":"Invalid result"}]}"#.utf8),
                    url: request.url!, statusCode: 200)
            })
        precondition(invalid.overrides[source.id] == nil)
        let foreign = try await SourceSubscriptionVerifier.verifyChangedSearches(plan,
            baselines: baselines, installed: baselines, item: { _, raw in
                SourceItemRef(sourceID: "jibi", pageURL: raw, kind: .work)
            }, fetch: fetch)
        precondition(foreign.overrides[source.id] == nil, "A foreign source identity must not verify the rule")
    }

    private static func dynamicPlaybackChoices() async throws {
        let transport = DynamicChoiceTransport()
        let source = RuntimeSource.native("senfun")
        let client = MobileSourceClient(source: source, fetch: { try await transport.fetch($0) })
        let work = try client.work(at: "https://senfun.in/voddetail/42.html")
        let flow = MobileSourceFlow(client: client, enabled: true)
        flow.open(work)
        await SourceRegression.idle(flow)
        let initialCalls = await transport.apiCalls
        precondition(initialCalls == 0 && flow.catalog != nil)
        flow.play(flow.catalog!.lines[0].episodes[0])
        await SourceRegression.idle(flow)
        precondition(flow.resolved == nil && flow.playbackOptions.count == 2)
        let backup = flow.playbackOptions.first { $0.qualityID == "BACKUP (2)" }!
        flow.choosePlaybackOption(backup)
        await SourceRegression.idle(flow)
        let resolved = flow.takeResolved()!
        precondition(resolved.url.absoluteString == "https://media.example/one-backup.m3u8")
        precondition(resolved.context.selection.qualityID == "BACKUP (2)")
        try ConfirmedSourceMapping(context: resolved.context, sourceTitle: "Dynamic fixture").validateForPersistence()
        let continuation = MobileSourceContinuation(client: client, authority: { source.configurationRevision })
        let next = try await continuation.resolve(after: resolved.context, next: true, currentTitle: resolved.title)!
        precondition(next.url.absoluteString == "https://media.example/two-backup.m3u8")
        precondition(next.context.selection.qualityID == "BACKUP (2)")
        await transport.removeBackup()
        do { _ = try await continuation.resolve(after: resolved.context, next: false, currentTitle: resolved.title); fatalError("Missing exact dynamic stream fell back") }
        catch MobileNextEpisodeError.qualityUnavailable {}
        let videoSource = RuntimeSource.native("hanime1")
        let video = try videoSource.item("https://hanime1.me/watch?v=42")
        let selected = PlayableSelection(item: video, episode: video, lineID: "0", qualityID: "720p", classification: videoSource.classification)
        let context = PlaybackContext(work: .source(video), episode: .source(sourceID: videoSource.id, workID: "42", episodeID: "720p"),
            selection: try videoSource.mappingSelection(selected), configurationRevision: videoSource.configurationRevision)
        try ConfirmedSourceMapping(context: context, sourceTitle: "Standalone video").validateForPersistence()
        var missingQuality = selected; missingQuality.qualityID = nil
        var wrongLine = selected; wrongLine.lineID = "1"
        var differentPage = selected
        differentPage.episode = SourceItemRef(sourceID: video.sourceID, pageURL: "https://hanime1.me/watch?v=43", kind: .video)
        var differentSource = selected
        differentSource.episode = SourceItemRef(sourceID: "jibi", pageURL: video.pageURL, kind: .video)
        var mixedKinds = selected
        mixedKinds.episode = SourceItemRef(sourceID: video.sourceID, pageURL: video.pageURL, kind: .episode)
        for choice in [missingQuality, wrongLine, differentPage, differentSource, mixedKinds] {
            let invalid = PlaybackContext(work: context.work, episode: context.episode, selection: choice,
                configurationRevision: context.configurationRevision)
            do {
                try ConfirmedSourceMapping(context: invalid, sourceTitle: "Standalone video").validateForPersistence()
                fatalError("Invalid standalone video identity persisted")
            } catch PlaybackFailure.unsupportedResponse {}
        }
        precondition(videoSource.classification.kind != .anime)
    }
}
