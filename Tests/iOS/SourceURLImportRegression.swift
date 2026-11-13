import SourceCore
import SourceRuntime
import Foundation

private actor SourceImportGate {
    private var continuation: CheckedContinuation<Data, Never>?
    let data: Data
    init(_ data: Data) { self.data = data }
    var waiting: Bool { continuation != nil }
    func fetch() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: data); continuation = nil }
}

@MainActor enum SourceURLImportRegression {
    static func run(root: URL) async throws {
        let original = try Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-import-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"))
        let expected: Set<String> = ["xifan", "girigiri", "didahd", "jibi", "eacg", "senfun", "kanba", "haixing", "yinghua", "dilidili", "youknow", "hanime1", "wedm", "fengche", "rebo", "mutedm", "fqdm"]
        precondition(Set(library.sources.map(\.id)) == expected)
        precondition(library.sources.allSatisfy { !$0.imported && $0.search == nil })
        precondition(library.sources.allSatisfy { !library.client(for: $0.source).capabilities.contains(.search) })
        precondition(!FileManager.default.fileExists(atPath: directory.path))
        let keys = expected.union(["imported-json"]).map { "mobile.sources." + $0 + ".enabled" }
        let prior = Dictionary(uniqueKeysWithValues: keys.map { ($0, UserDefaults.standard.object(forKey: $0) ?? NSNull()) })
        defer {
            for (key, value) in prior {
                if value is NSNull { UserDefaults.standard.removeObject(forKey: key) }
                else { UserDefaults.standard.set(value, forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        library.reload()
        for entry in library.sources {
            do { _ = try library.configurationRevision(for: entry.id); fatalError("New builtin enabled without consent") }
            catch PlaybackFailure.sourceDisabled {}
        }
        for invalid in ["http://configuration.example/source.json", "https://user:secret@configuration.example/source.json", "https://configuration.example/source.json#fragment", "file:///tmp/source.json", "https://localhost/source.json", "https://127.0.0.1/source.json", "https://192.168.1.1/source.json", "https://router.local/source.json", "https://configuration.example:8443/source.json"] {
            precondition(MobileSourceImportTransport.parse(invalid) == nil)
        }
        let configurationURL = URL(string: "https://configuration.example/folder/source.json")!
        let single = MobileSourceURLImport(fetch: { _ in original })
        single.load(configurationURL.absoluteString, library: library)
        await idle(single)
        precondition(single.draft?.configuration.id == "fqdm" && single.failure == nil)
        precondition(library.sources.first(where: { $0.id == "fqdm" })?.imported == false)
        single.cancel()
        precondition(single.draft == nil)
        var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        object["id"] = "imported-json"
        var hijack = object
        hijack["id"] = "jibi"
        do { _ = try MobileSourceLibrary.validate(JSONSerialization.data(withJSONObject: hijack)); fatalError("Native source ID hijacked") }
        catch MobileSourceError.nativeConflict {}
        let nativeHost = String(decoding: original, as: UTF8.self).replacingOccurrences(of: "fqdm.cc", with: "jibi.cc")
        do { _ = try MobileSourceLibrary.validate(Data(nativeHost.utf8)); fatalError("Native source host hijacked") }
        catch MobileSourceError.nativeConflict {}
        object["name"] = "Explicit configured source"
        let configured = try JSONSerialization.data(withJSONObject: object)
        let list = try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [object, "source.json"]])
        let importer = MobileSourceURLImport(fetchResponse: { url in
            if url.path.hasSuffix("list.json") { return .init(data: list, url: URL(string: "https://configuration.example/final/list.json")!) }
            precondition(url.absoluteString == "https://configuration.example/final/source.json")
            return .init(data: original, url: url)
        })
        importer.load("https://configuration.example/list.json", library: library)
        await idle(importer)
        let batch = importer.batch!
        precondition(batch.drafts.map { $0.configuration.id } == ["imported-json", "fqdm"])
        try library.apply(batch)
        precondition(library.sources.first(where: { $0.id == "imported-json" })?.imported == true)
        precondition(library.sources.first(where: { $0.id == "fqdm" })?.search != nil)
        let duplicate = try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [object, object]])
        let duplicateImporter = MobileSourceURLImport(fetch: { _ in duplicate })
        duplicateImporter.load(configurationURL.absoluteString, library: library)
        await idle(duplicateImporter)
        precondition(duplicateImporter.failure == .invalidConfiguration && duplicateImporter.batch == nil)
        let gate = SourceImportGate(configured)
        let cancelled = MobileSourceURLImport(fetch: { _ in await gate.fetch() })
        cancelled.load(configurationURL.absoluteString, library: library)
        while !(await gate.waiting) { await Task.yield() }
        cancelled.cancel()
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        precondition(cancelled.draft == nil && cancelled.batch == nil && cancelled.subscriptionPreview == nil && !cancelled.busy)
        try await customSubscription(original: original, directory: directory.appendingPathComponent("Subscription"))
        try await staticSubscription(directory: directory.appendingPathComponent("StaticSubscription"))
        try inactiveLegacy(original: original, directory: directory.appendingPathComponent("Legacy"))
        print("PASS: exact seventeen managed sources, opt-in search, configured imports, custom subscription URLs, cancellation and inactive legacy byte preservation")
    }

    private static func staticSubscription(directory: URL) async throws {
        let rules: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": ["name": "Static fixture", "searchConfig": [
            "searchUrl": "https://static.example/search/{keyword}?page={page}", "subjectFormatId": "indexed",
            "selectorSubjectFormatIndexed": ["selectNames": ".row .title", "selectLinks": ".row a"],
            "channelFormatId": "index-grouped", "selectorChannelFormatFlattened": [
                "selectChannelNames": ".line", "selectEpisodeLists": ".episodes", "selectEpisodesFromList": "a"]]]]
        let data = try JSONSerialization.data(withJSONObject: ["mediaSources": [rules]])
        let configuration = try SourceWebConfigurationConverter.configuration(rules)
        let key = "mobile.sources." + configuration.id + ".enabled"
        let old = UserDefaults.standard.object(forKey: key)
        defer {
            if let old { UserDefaults.standard.set(old, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let library = MobileSourceLibrary(directory: directory)
        let importer = MobileSourceURLImport(fetch: { _ in data })
        importer.load("https://mirror.example/static.json", library: library)
        await idle(importer)
        guard let preview = importer.subscriptionPreview else { fatalError("Static subscription preview missing") }
        precondition(preview.state.configurations.keys.sorted() == [configuration.id])
        precondition(!library.sources.contains { $0.id == configuration.id })
        try library.applySubscription(preview)
        precondition(!UserDefaults.standard.bool(forKey: key))
        let reopened = MobileSourceLibrary(directory: directory)
        guard let entry = reopened.sources.first(where: { $0.id == configuration.id }) else { fatalError("Static source not reloaded") }
        precondition(entry.source.configurationRevision == configuration.configurationRevision)
        let client = MobileSourceClient(source: entry.source, search: entry.search, fetch: { request in
            let html: String
            switch request.url!.path {
            case let path where path.hasPrefix("/search/"):
                html = "<div class='row'><span class='title'>Fixture</span><a href='/work/alpha'>Open</a></div>"
            case "/work/alpha":
                html = "<h2 class='line'>Line A</h2><div class='episodes'><a href='/watch/alpha-one'>第1集</a><a href='/watch/alpha-two'>第2集</a></div>"
            case "/watch/alpha-two": html = "<video src='https://media.example/alpha-two.mp4'></video>"
            default: throw MobileSourceError.invalidSelection
            }
            return SourceHTTPResponse(data: Data(html.utf8), url: request.url!, statusCode: 200)
        })
        let page = try await client.search("Fixture")
        precondition(page.works.count == 1)
        let catalog = try await client.catalog(page.works[0])
        let episode = catalog.lines[0].episodes[1]
        let context = try client.playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil)
        precondition(context.selection.episode?.kind == .episode)
        let restored = try client.episode(matching: context.selection, in: catalog)
        precondition(restored == episode)
        let media = try await client.resolve(episode, in: catalog)
        precondition(media.path == "/alpha-two.mp4")
        // A preview is bound to both configured and search revisions, even for new sources.
        do { try library.applySubscription(preview); fatalError("Stale static preview accepted") }
        catch MobileSubscriptionError.stale {}
    }

    private static func customSubscription(original: Data, directory: URL) async throws {
        let library = MobileSourceLibrary(directory: directory)
        let baselines = try SourceSubscriptionBaselines.load()
        let baseline = baselines["fqdm"]!
        let item: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": ["name": "Tomato rules", "searchConfig": [
            "searchUrl": baseline.search.url.replacingOccurrences(of: "{query}", with: "{keyword}"), "subjectFormatId": "a",
            "selectorSubjectFormatA": ["selectLists": "a.subscription-result"]]]]
        let data = try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
        let fetch: SourceHTTPTransport.Fetch = { request in
            SourceHTTPResponse(data: Data("<a class='subscription-result' href='/index.php/vod/detail/id/42.html'>Fixture</a>".utf8), url: request.url!, statusCode: 200)
        }
        let importer = MobileSourceURLImport(searchFetch: fetch, fetch: { _ in data })
        importer.load("https://mirror.example/rules.json", library: library)
        await idle(importer)
        precondition(importer.failure == nil && importer.subscriptionPreview?.state.overrides.keys.sorted() == ["fqdm"])
        precondition(library.sources.first(where: { $0.id == "fqdm" })?.search == nil, "Downloading a custom feed must not apply it")
        importer.cancel()
        precondition(importer.subscriptionPreview == nil)
        let nested = try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [item]]])
        let mirror = MobileSourceURLImport(searchFetch: fetch, fetchResponse: { _ in
            .init(data: nested, url: URL(string: "https://raw.githubusercontent.com/fixture/sources/main/online.json")!)
        })
        mirror.load("https://mirror.example/online.json", library: library)
        await idle(mirror)
        precondition(mirror.failure == nil && mirror.subscriptionPreview?.state.overrides.keys.sorted() == ["fqdm"], "Redirected nested subscriptions must use the same preview flow")
        mirror.cancel()
        let rejected = MobileSourceURLImport(fetchResponse: { _ in
            .init(data: data, url: URL(string: "https://127.0.0.1/rules.json")!)
        })
        rejected.load("https://mirror.example/rules.json", library: library)
        await idle(rejected)
        precondition(rejected.failure == .invalidConfiguration && rejected.subscriptionPreview == nil)
        let revision = library.sources.first(where: { $0.id == "fqdm" })!.source.configurationRevision
        importer.load(SourceSubscriptionTransport.endpoint.absoluteString, library: library)
        await idle(importer)
        precondition(importer.failure == nil && importer.draft == nil && importer.batch == nil)
        let preview = importer.subscriptionPreview!
        precondition(preview.state.overrides.keys.sorted() == ["fqdm"])
        try library.applySubscription(preview)
        let source = library.sources.first(where: { $0.id == "fqdm" })!
        precondition(source.source.configurationRevision == revision && source.search != nil && !source.imported)
        precondition(!UserDefaults.standard.bool(forKey: "mobile.sources.fqdm.enabled"))
        precondition(library.client(for: source.source).capabilities.contains(.search))
        precondition(library.sources.count == 17)
    }

    private static func inactiveLegacy(original: Data, directory: URL) throws {
        let id = "jibi"
        let legacy: [String: Any] = ["id": id, "name": "Saved user selector", "version": 3,
            "hosts": ["legacy.example"], "mediaHosts": [], "anonymousExternalHTTPSMedia": true, "credentialHosts": [],
            "capabilities": ["information", "resolve", "episodes", "lines", "mpv", "search"],
            "route": ["pattern": "^/(.*)$", "idGroup": 1, "detailTemplate": "https://legacy.example/{id}"],
            "catalog": ["url": "https://legacy.example/{id}", "format": "web-selector"],
            "player": ["format": "web-selector", "allowedExtensions": ["m3u8", "mp4"]],
            "search": ["url": "https://legacy.example/search?q={query}", "format": "web-selector", "queryParameter": "", "pageParameter": "", "rowsPerPage": 100],
            "webSelector": ["baseURL": "https://legacy.example", "relativeLinksUseSearchURL": true, "subjectFormat": "a", "searchNames": "a.result", "searchLinks": "a.result", "channelFormat": "no-channel", "episodeNames": "a.episode"]]
        let data = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys])
        let old = try SourceConfiguration.load(data: data)
        do { _ = try MobileSourceLibrary.validate(data); fatalError("New selector import accepted") }
        catch MobileSourceError.inactiveWebSelector {}
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacyFile = directory.appendingPathComponent(id + ".json")
        try data.write(to: legacyFile)
        let key = "mobile.sources." + id + ".enabled"
        UserDefaults.standard.set(true, forKey: key)
        let collectionFile = directory.appendingPathComponent("Library/library.json")
        let collection = MobileLibrary(file: directory.appendingPathComponent("Library/favorites.json"), libraryFile: collectionFile)
        let work = PlaybackWorkIdentity.bangumi(141)
        let episode = PlaybackEpisodeIdentity.bangumi(142, type: 0, sort: 1)
        let mapping = ConfirmedSourceMapping(context: PlaybackContext(work: work, episode: episode,
            selection: PlayableSelection(item: .init(sourceID: id, pageURL: "https://legacy.example/show?id=1", kind: .work),
                episode: .init(sourceID: id, pageURL: "https://legacy.example/watch?id=1", kind: .episode), lineID: "1"),
            configurationRevision: old.configurationRevision), sourceTitle: "Saved title")
        try collection.saveMapping(mapping)
        let collectionBytes = try Data(contentsOf: collectionFile)
        let library = MobileSourceLibrary(directory: directory)
        let reviewed = library.sources.first { $0.id == id }!
        precondition(!reviewed.imported && reviewed.source.configured == nil)
        precondition(reviewed.source.configurationRevision != mapping.context.configurationRevision)
        let stale = MobileSourceFlow(client: library.client(for: reviewed.source), requestedWork: work,
            requestedEpisode: episode, authority: { reviewed.source.configurationRevision }, resumeMapping: mapping)
        stale.updateAccess(enabled: true, configurationRevision: reviewed.source.configurationRevision)
        precondition(stale.requiresReconfirmation && stale.failure == .configurationChanged)
        precondition(library.issues.contains { $0.contains("webSelector") && $0.contains("retained") })
        precondition(UserDefaults.standard.bool(forKey: key))
        let legacyBytes = try Data(contentsOf: legacyFile)
        precondition(legacyBytes == data)
        let after = try Data(contentsOf: collectionFile)
        precondition(after == collectionBytes && collection.storedMapping(for: work, episode: episode) == mapping)
        // The batch authority reserves inactive IDs independently, without discarding healthy imports.
        struct State: Codable { let version: Int; let configurations: [String: Data] }
        var config = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        config["id"] = "healthy-configured"
        let healthy = try JSONSerialization.data(withJSONObject: config)
        var invalidLegacy = legacy
        invalidLegacy["version"] = 2
        let invalidData = try JSONSerialization.data(withJSONObject: invalidLegacy, options: [.prettyPrinted, .sortedKeys])
        do { _ = try SourceConfiguration.load(data: invalidData); fatalError("Invalid legacy schema was accepted") }
        catch SourceConfiguration.ConfigurationError.invalidConfiguration {}
        let stateFile = directory.appendingPathComponent("ConfigurationImports/state.json")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let builtinIDs = Set(try RuntimeSource.builtins().map(\.id))
        for inactiveData in [data, invalidData] {
            let batchBytes = try JSONEncoder().encode(State(version: 1,
                configurations: [id: inactiveData, "healthy-configured": healthy]))
            try batchBytes.write(to: stateFile, options: .atomic)
            library.reload()
            precondition(Set(library.sources.map(\.id)) == builtinIDs.union(["healthy-configured"]),
                         "One incompatible batch entry must not clear healthy imports or reviewed built-ins")
            precondition(library.sources.contains { $0.id == id && !$0.imported && $0.source.configured == nil })
            precondition(library.sources.contains {
                $0.id == "healthy-configured" && $0.imported && $0.source.configured != nil
            })
            precondition(library.issues.contains { $0.hasPrefix(id + " · ") })
            precondition(!library.issues.contains("ConfigurationImports/state.json"))
            precondition(UserDefaults.standard.bool(forKey: key))
            let retainedBatch = try Data(contentsOf: stateFile)
            let retainedLegacy = try Data(contentsOf: legacyFile)
            let retainedMapping = try Data(contentsOf: collectionFile)
            precondition(retainedBatch == batchBytes && retainedLegacy == data && retainedMapping == collectionBytes)
        }
        // Entry-level isolation must not make unknown root schemas or versions recoverable.
        for broken in [Data("[]".utf8), Data(#"{"version":1,"configurations":[]}"#.utf8),
                       Data(#"{"version":2,"configurations":{}}"#.utf8)] {
            try broken.write(to: stateFile, options: .atomic)
            library.reload()
            precondition(library.sources.isEmpty && library.issues.contains("ConfigurationImports/state.json"))
            let retainedState = try Data(contentsOf: stateFile)
            let retainedLegacy = try Data(contentsOf: legacyFile)
            let retainedMapping = try Data(contentsOf: collectionFile)
            precondition(retainedState == broken && retainedLegacy == data && retainedMapping == collectionBytes)
        }
    }

    private static func idle(_ importer: MobileSourceURLImport) async {
        while importer.busy { await Task.yield() }
    }
}
