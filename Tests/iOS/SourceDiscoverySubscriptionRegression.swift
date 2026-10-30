import Foundation

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
        let sourceLibrary = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"), bundled: { [config] })
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
            return MobileSourceClient(configuration: config) { url in
                if url.path.contains("search") { return searchBody }
                if url.path.contains("detail") { return url.path.contains("43") ? secondCatalog : firstCatalog }
                return player
            }
        }
        let discovery = MobileSourceDiscovery()
        discovery.find(anime: anime, episode: requested, sources: [config], library: library, authority: authority, client: { _ in client(titles: [title]) })
        while discovery.busy { await Task.yield() }
        precondition(discovery.automatic != nil && discovery.candidates.count == 1)
        let automatic = discovery.automatic!
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
        discovery.find(anime: anime, episode: requested, sources: [config], library: library, authority: authority, client: { _ in client(titles: [title]) })
        precondition(!discovery.busy && discovery.automatic == nil) // Invalid saved choice is never bypassed.
        try library.removeMapping(for: .bangumi(anime.id), episode: .bangumi(requested.id, type: 0, sort: 2))
        for (titles, missing) in [([title, title], false), (["Trust Fixture Season 3 TV 2025"], false), ([title], true), (["Trust Fixture Season 2"], false)] {
            discovery.find(anime: anime, episode: requested, sources: [config], library: library, authority: authority, client: { _ in client(titles: titles, missing: missing) })
            while discovery.busy { await Task.yield() }
            precondition(discovery.automatic == nil)
        }
        enabled = false
        discovery.find(anime: anime, episode: requested, sources: [config], library: library, authority: authority, client: { _ in fatalError("Disabled source sent a request") })
        while discovery.busy { await Task.yield() }
        precondition(discovery.automatic == nil)
        enabled = true
        for change in [0, 1, 2] {
            let gate = DiscoverySearchGate(search: search([title]), catalog: catalog("42"), player: player)
            discovery.find(anime: anime, episode: requested, sources: [config], library: library, authority: authority,
                client: { _ in MobileSourceClient(configuration: config) { await gate.fetch($0) } })
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
        let originalRevision = sourceLibrary.sources[0].configuration.configurationRevision
        service.check(library: sourceLibrary, fetch: { body }, probe: { _ in true })
        while service.busy { await Task.yield() }
        precondition(service.preview?.state.overrides.count == 1)
        let cancelled = service.preview!
        service.cancel()
        precondition(sourceLibrary.sources[0].configuration.configurationRevision == originalRevision)
        do { try service.apply(cancelled, library: sourceLibrary); fatalError("Cancelled preview applied") } catch {}
        service.check(library: sourceLibrary, fetch: { body }, probe: { _ in true })
        while service.busy { await Task.yield() }
        let preview = service.preview!
        let defaultsName = "subscription-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set(false, forKey: "mobile.sources.fqdm.enabled")
        try service.apply(preview, library: sourceLibrary)
        let updatedRevision = sourceLibrary.sources[0].configuration.configurationRevision
        precondition(updatedRevision != originalRevision)
        precondition(!defaults.bool(forKey: "mobile.sources.fqdm.enabled"))
        let reopened = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"), bundled: { [config] })
        precondition(reopened.sources[0].configuration.configurationRevision == updatedRevision)
        precondition(reopened.sources[0].configuration.player.format == config.player.format)
        let oldMappingFlow = MobileSourceFlow(client: client(titles: [title]), requestedWork: .bangumi(anime.id),
            requestedEpisode: .bangumi(requested.id, type: 0, sort: 2), library: library,
            authority: { updatedRevision }, resumeMapping: ConfirmedSourceMapping(context: try client(titles: [title]).playbackContext(automatic.episode!, in: automatic.catalog, requestedWork: .bangumi(anime.id), requestedEpisode: .bangumi(requested.id, type: 0, sort: 2)), sourceTitle: title))
        oldMappingFlow.updateAccess(enabled: true, configurationRevision: updatedRevision)
        precondition(oldMappingFlow.requiresReconfirmation && oldMappingFlow.failure == .configurationChanged)
        service.check(library: sourceLibrary, fetch: { body }, probe: { _ in true })
        while service.busy { await Task.yield() }
        let stale = service.preview!
        var object = try JSONSerialization.jsonObject(with: config.encodedData()) as! [String: Any]
        object["name"] = "Changed local configuration"
        let changed = try JSONSerialization.data(withJSONObject: object)
        _ = try sourceLibrary.apply(.init(configuration: SourceConfiguration.load(data: changed), data: changed))
        do { try service.apply(stale, library: sourceLibrary); fatalError("Stale preview applied") } catch {}
        let unsupported = try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [["factoryId": "web-selector", "version": 2, "arguments": ["name": "fqdm", "searchConfig": ["searchUrl": "https://unknown.example/search?wd={keyword}"]]]]]])
        let rejected = try MobileSubscriptionConverter.convert(unsupported, baselines: [config], current: [config])
        precondition(rejected.state.overrides.isEmpty)
        precondition(sourceLibrary.sources[0].configuration.configurationRevision != updatedRevision)
        precondition(sourceLibrary.sources[0].configuration.search?.resultsSelector == config.search?.resultsSelector)
        let failedDirectory = directory.appendingPathComponent("UnwritableSources")
        try FileManager.default.createDirectory(at: failedDirectory, withIntermediateDirectories: true)
        try Data("not a folder".utf8).write(to: failedDirectory.appendingPathComponent("SearchSubscription"))
        let alternativeBody = try subscription(selector: "a.different-result")
        let firstRoot = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let secondRoot = try JSONSerialization.jsonObject(with: alternativeBody) as! [String: Any]
        let firstItems = (firstRoot["exportedMediaSourceDataList"] as! [String: Any])["mediaSources"] as! [Any]
        let secondItems = (secondRoot["exportedMediaSourceDataList"] as! [String: Any])["mediaSources"] as! [Any]
        let duplicateBody = try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": firstItems + secondItems]])
        let duplicates = try MobileSubscriptionConverter.convert(duplicateBody, baselines: [config], current: [config])
        precondition(duplicates.state.overrides.isEmpty)
        let failedLibrary = MobileSourceLibrary(directory: failedDirectory, bundled: { [config] })
        let atomic = MobileSourceSubscription()
        atomic.check(library: failedLibrary, fetch: { body }, probe: { _ in true })
        while atomic.busy { await Task.yield() }
        do { try atomic.apply(atomic.preview!, library: failedLibrary); fatalError("Storage failure accepted") } catch {}
        precondition(failedLibrary.sources[0].configuration.configurationRevision == originalRevision)
    }
}
