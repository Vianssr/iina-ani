import Foundation

actor RetryTransport {
    var calls = 0
    let body: Data
    init(body: Data) { self.body = body }
    func fetch(_ url: URL) throws -> Data {
        calls += 1
        if calls == 1 { throw URLError(.timedOut) }
        return body
    }
}

/// Explicit gates make in-flight authority changes deterministic, including transports that ignore cancellation.
actor MappingTransport {
    enum Endpoint: Equatable { case catalog, player }
    var catalogData: Data
    var playerData: Data
    private var held: Endpoint?
    private var pending: CheckedContinuation<Data, Never>?
    private var pendingData: Data?
    private(set) var catalogCalls = 0
    private(set) var playerCalls = 0
    var waiting: Bool { pending != nil }
    init(catalog: Data, player: Data) { catalogData = catalog; playerData = player }
    func hold(_ endpoint: Endpoint) { held = endpoint }
    func release() {
        guard let pending, let pendingData else { return }
        self.pending = nil; self.pendingData = nil
        pending.resume(returning: pendingData)
    }
    func fetch(_ url: URL) async -> Data {
        let endpoint: Endpoint = url.path.contains("detail") || url.path.contains("metadata") || url.path.contains("/catalog") ? .catalog : .player
        if endpoint == .catalog { catalogCalls += 1 } else { playerCalls += 1 }
        let data = endpoint == .catalog ? catalogData : playerData
        if endpoint == held {
            held = nil
            return await withCheckedContinuation { pending = $0; pendingData = data }
        }
        return data
    }
}

@main struct SourceRegression {
    static func rejects(_ operation: () async throws -> Void) async {
        do { try await operation(); fatalError("Accepted invalid input") } catch {}
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try await configurationFiles(root: root)
        try await SourceURLImportRegression.run(root: root)
        try await DefaultSubscriptionRegression.run(root: root)
        try MobileCSS1Regression.run(root: root)
        try await CSS1ClientRegression.run(root: root)
        try await CSS1IdentityRegression.run(root: root)
        if let option = CommandLine.arguments.firstIndex(of: "--css1-url"), CommandLine.arguments.indices.contains(option + 1) {
            let importer = MobileSourceURLImport()
            importer.load(CommandLine.arguments[option + 1])
            while importer.busy { try await Task.sleep(for: .milliseconds(20)) }
            guard let batch = importer.batch else { throw MobileSourceError.invalidResponse }
            print("LIVE CSS1: imported=\(batch.drafts.count), skipped=\(batch.notices.count)")
            for id in ["fanqie-dongman", "jibi-dongman", "wedm"] {
                guard let draft = batch.drafts.first(where: { $0.configuration.id == id }) else { continue }
                do {
                    let client = MobileSourceClient(configuration: draft.configuration)
                    let results = try await client.search("海贼王")
                    guard let work = results.works.first else { throw MobileSourceError.unavailable }
                    let catalog = try await client.catalog(work)
                    guard let episode = catalog.lines.first?.episodes.first else { throw MobileSourceError.unavailable }
                    let media = try await client.resolve(episode, in: catalog)
                    print("LIVE CSS1 \(id): search=\(results.works.count), lines=\(catalog.lines.count), resolved=\(media.pathExtension)")
                } catch {
                    print("LIVE CSS1 \(id): failed=\(MobileSourceClient.failure(for: error).rawValue)")
                }
            }
        }
        let config = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        if CommandLine.arguments.contains("--live") {
            let live = MobileSourceClient(configuration: config)
            do {
                let page = try await live.search("葬送的芙莉莲")
                print("LIVE: search candidates=\(page.works.count)")
                if let work = page.works.first {
                    let catalog = try await live.catalog(work)
                    print("LIVE: catalog lines=\(catalog.lines.count)")
                    if let episode = catalog.lines.first?.episodes.first {
                        _ = try await live.resolve(episode, in: catalog)
                        print("LIVE: selected episode resolved to validated HTTPS media (URL omitted)")
                    }
                }
            } catch { print("LIVE: source unavailable or response unsupported; no live playback claim") }
            return
        }
        try await SourceDiscoverySubscriptionRegression.run(root: root)
        try await CatalogDetailsRegression.run()
        let work = MobileSourceWork(item: SourceItemRef(sourceID: "fqdm", pageURL: "https://www.fqdm.cc/index.php/vod/detail/id/42.html", kind: .work), title: "Fixture")
        let search = "<div class='module-card-item-info'><div class='module-card-item-title'><a href='/index.php/vod/detail/id/42.html'>Fixture</a></div></div>"
        let catalog = "<div class='module-info-heading'><h1>Fixture</h1></div><div class='module-tab-item tab-item'><span>Line A</span></div><div class='module-play-list'><a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/1/nid/2.html'>Episode 2</a><a class='module-play-list-link' href='/index.php/vod/play/id/99/sid/1/nid/1.html'>Wrong work</a></div>"
        func player(_ id: String = "42", episode: Int = 2, paid: Int = 0, preview: Int = 0, media: String = "https://media.example.test/video.mp4") throws -> Data {
            let payload: [String: Any] = ["id": id, "sid": 1, "nid": episode, "points": paid, "trysee": preview, "encrypt": 0, "url": media]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return Data("<script>var player_aaaa=\(json);</script>".utf8)
        }
        let validPlayer = try player()
        let client = MobileSourceClient(configuration: config) { url in
            if url.path.contains("search") { return Data(search.utf8) }
            if url.path.contains("detail") { return Data(catalog.utf8) }
            return validPlayer
        }
        let result = try await client.search("Fixture & + 字")
        precondition(result.works == [work] && result.nextPage == nil)
        let list = try await client.catalog(work)
        precondition(list.lines.count == 1 && list.lines[0].episodes.count == 1)
        let second = list.lines[0].episodes[0]
        precondition(second.number == 2) // No positional fallback to episode 1.
        let media = try await client.resolve(second, in: list)
        precondition(media.host == "media.example.test")
        for data in [try player("99"), try player(episode: 1), try player(paid: 1), try player(preview: 30), try player(media: "http://media.example.test/video.mp4"), try player(media: "https://user:secret@media.example.test/video.mp4"), try player(media: "https://media.example.test/page.html")] {
            let invalid = MobileSourceClient(configuration: config) { _ in data }
            await rejects { _ = try await invalid.resolve(second, in: list) }
        }
        let unissued = MobileSourceEpisode(item: second.item, title: "Wrong", line: 1, number: 1)
        await rejects { _ = try await client.resolve(unissued, in: list) }
        let blocked = MobileSourceClient(configuration: config) { _ in Data("<form id='challenge-form'></form>".utf8) }
        await rejects { _ = try await blocked.search("Fixture") }
        let empty = MobileSourceClient(configuration: config) { _ in Data("<html><body>No results</body></html>".utf8) }
        let noResults = try await empty.search("Fixture")
        precondition(noResults.works.isEmpty)
        let next = MobileSourceClient(configuration: config) { _ in Data((search + "<a rel='next' href='?page=2'>Next</a>").utf8) }
        let paginated = try await next.search("Fixture")
        precondition(paginated.nextPage == 2)
        // A transport that ignores cancellation still cannot mutate the latest flow.
        let slow = MobileSourceClient(configuration: config) { _ in
            try? await Task.sleep(for: .milliseconds(120))
            return Data(search.utf8)
        }
        let flow = MobileSourceFlow(client: slow, enabled: true)
        flow.search("old")
        try await Task.sleep(for: .milliseconds(20))
        flow.cancel()
        try await Task.sleep(for: .milliseconds(180))
        precondition(flow.results.isEmpty && !flow.busy && !flow.failed && flow.resolved == nil)
        let retryTransport = RetryTransport(body: Data(search.utf8))
        let retryFlow = MobileSourceFlow(client: MobileSourceClient(configuration: config) { try await retryTransport.fetch($0) }, enabled: true)
        retryFlow.search("Fixture")
        while retryFlow.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(retryFlow.failure == .network && retryFlow.canRetry)
        retryFlow.retry()
        while retryFlow.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(!retryFlow.failed && retryFlow.results.count == 1)
        let encoded = MobileSourceClient(configuration: config) { url in
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            precondition(items.first { $0.name == "wd" }?.value == "A & + 字")
            precondition(items.first { $0.name == "page" }?.value == "2")
            return Data(search.utf8)
        }
        _ = try await encoded.search("A & + 字", page: 2)
        let requested = try JSONDecoder().decode(CatalogEpisode.self, from: Data(#"{"id":901,"type":1,"sort":13.5,"ep":1,"name":"Special"}"#.utf8))
        let success = MobileSourceFlow(client: client, requestedWork: .bangumi(101),
            requestedEpisode: .bangumi(requested.id, type: requested.type, sort: requested.sort), enabled: true)
        success.search("Fixture")
        while success.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(success.results.count == 1)
        success.open(work)
        while success.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(success.catalog != nil)
        success.play(second)
        while success.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(success.resolved?.url == media)
        let handoff = success.takeResolved()!
        precondition(handoff.context.work == .bangumi(101))
        precondition(handoff.context.episode == .bangumi(901, type: 1, sort: 13.5))
        precondition(handoff.context.episode.bangumiID != second.number) // Never use the source button's number as the Bangumi ID.
        precondition(handoff.context.selection.item == work.item && handoff.context.selection.episode == second.item)
        precondition(handoff.context.selection.lineID == "1" && handoff.context.selection.qualityID == nil)
        precondition(handoff.context.configurationRevision == config.configurationRevision)
        precondition(success.takeResolved() == nil)
        try await mobileContracts(config: config, client: client, work: work, catalog: list, episode: second, player: validPlayer)
        try await mappingContracts(root: root, config: config, work: work, catalogData: Data(catalog.utf8),
                                   player: validPlayer, wrongPlayer: try player("99"),
                                   paidPlayer: try player(paid: 1), previewPlayer: try player(preview: 30))
        try await nextEpisodeContracts(config: config, work: work)
        success.cancel()
        precondition(success.resolved == nil)
        let future = try JSONDecoder().decode(CatalogEpisode.self, from: Data(#"{"id":1,"type":0,"sort":13,"ep":1,"name":"Future","airdate":"2999-01-01"}"#.utf8))
        precondition(future.isUpcoming() && future.number == "1")
        print("PASS: source search, pagination, catalog identity, missing episode, exact resolution, paid/preview/URL rejection, challenge, cancellation, flow and future episode")
    }
}

extension SourceRegression {
    @MainActor static func idle(_ flow: MobileSourceFlow) async {
        while flow.busy { await Task.yield() }
    }

    @MainActor static func mappingContracts(root: URL, config: SourceConfiguration, work: MobileSourceWork,
                                            catalogData: Data, player: Data, wrongPlayer: Data,
                                            paidPlayer: Data, previewPlayer: Data) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "source-mapping-regression-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        let original = try Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        var alternateObject = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        alternateObject["id"] = "aaa-alternative"
        let alternate = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: alternateObject))
        let sources = MobileSourceLibrary(directory: directory.appendingPathComponent("Sources"), bundled: { [config, alternate] })
        precondition(sources.sources.first?.id == alternate.id)
        let enabledKey = "mobile.sources." + config.id + ".enabled"
        defaults.set(true, forKey: enabledKey)
        let libraryURL = directory.appendingPathComponent("Library/library.json")
        let legacyURL = libraryURL.deletingLastPathComponent().appendingPathComponent("favorites.json")
        let requestedWork = PlaybackWorkIdentity.bangumi(301)
        let requestedEpisode = PlaybackEpisodeIdentity.bangumi(501, type: 0, sort: 2)
        let library = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        @MainActor func flow(_ transport: MappingTransport, library: MobileLibrary,
                  episode: PlaybackEpisodeIdentity = .bangumi(501, type: 0, sort: 2)) -> MobileSourceFlow {
            let candidate = MobileSourceFlow(client: MobileSourceClient(configuration: config) { await transport.fetch($0) },
                requestedWork: requestedWork, requestedEpisode: episode, enabled: true, library: library,
                authority: { try sources.configurationRevision(for: config.id, defaults: defaults) })
            candidate.updateAccess(enabled: true, configurationRevision: config.configurationRevision)
            return candidate
        }
        @MainActor func confirm(_ candidate: MobileSourceFlow) async {
            candidate.open(work)
            await idle(candidate)
            precondition(candidate.catalog != nil)
            candidate.play(candidate.catalog!.lines[0].episodes[0])
            await idle(candidate)
        }

        // Only the explicit, parser-verified choice commits, before the one-shot consumer handoff.
        let initial = flow(MappingTransport(catalog: catalogData, player: player), library: library)
        precondition(library.mapping(for: requestedWork, episode: requestedEpisode) == nil)
        await confirm(initial)
        precondition(initial.storageFailure == nil && initial.failure == nil)
        let confirmed = library.mapping(for: requestedWork, episode: requestedEpisode)!
        precondition(confirmed.context.selection.item.sourceID == config.id)
        precondition(confirmed.context.selection.episode?.pageURL.contains("/nid/2.html") == true)
        precondition(confirmed.context.selection.lineID == "1" && confirmed.context.selection.accountID == nil)
        precondition(initial.takeResolved() != nil && initial.takeResolved() == nil)

        // Restart selects the saved source, not the first source, and performs fresh catalogue/player requests.
        let restarted = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        let reuseTransport = MappingTransport(catalog: catalogData, player: player)
        let reuse = flow(reuseTransport, library: restarted)
        precondition(reuse.savedMapping == confirmed && reuse.canPlaySaved && reuse.results.isEmpty && reuse.catalog == nil)
        precondition(reuse.resolved == nil)
        reuse.playSaved()
        await idle(reuse)
        let reuseCatalogCalls = await reuseTransport.catalogCalls
        let reusePlayerCalls = await reuseTransport.playerCalls
        precondition(reuseCatalogCalls == 1 && reusePlayerCalls == 1)
        precondition(reuse.takeResolved()?.context == confirmed.context && reuse.takeResolved() == nil)

        // History resumes its own exact selection without recreating a removed library mapping.
        try restarted.removeMapping(for: requestedWork, episode: requestedEpisode)
        let historyTransport = MappingTransport(catalog: catalogData, player: player)
        let historyResume = MobileSourceFlow(client: MobileSourceClient(configuration: config) { await historyTransport.fetch($0) },
            requestedWork: requestedWork, requestedEpisode: requestedEpisode,
            authority: { try sources.configurationRevision(for: config.id, defaults: defaults) },
            resumeMapping: confirmed)
        historyResume.playSaved()
        await idle(historyResume)
        precondition(historyResume.takeResolved()?.context == confirmed.context)
        precondition(restarted.storedMapping(for: requestedWork, episode: requestedEpisode) == nil)
        try restarted.saveMapping(confirmed)

        // Disablement sends no request; enabling unchanged configuration permits explicit reuse.
        defaults.set(false, forKey: enabledKey)
        let disabledTransport = MappingTransport(catalog: catalogData, player: player)
        let disabled = flow(disabledTransport, library: restarted)
        precondition(disabled.failure == .sourceDisabled && !disabled.canPlaySaved)
        disabled.playSaved()
        let disabledCalls = await disabledTransport.catalogCalls
        precondition(disabledCalls == 0 && restarted.mappingFailure(for: requestedWork, episode: requestedEpisode) == nil)
        defaults.set(true, forKey: enabledKey)
        disabled.updateAccess(enabled: true, configurationRevision: config.configurationRevision)
        precondition(disabled.canPlaySaved && disabled.failure == nil)
        disabled.playSaved()
        await idle(disabled)
        precondition(disabled.takeResolved() != nil)

        // Changed original type/sort is stale, not absent, even if the previous metadata returns after restart.
        let changedDomain = flow(MappingTransport(catalog: catalogData, player: player), library: restarted,
                                 episode: .bangumi(501, type: 1, sort: 2.5))
        precondition(changedDomain.requiresReconfirmation && changedDomain.failure == .missingEpisode)
        let domainRestart = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        let blockedDomain = flow(MappingTransport(catalog: catalogData, player: player), library: domainRestart)
        precondition(blockedDomain.requiresReconfirmation && !blockedDomain.canPlaySaved)
        blockedDomain.chooseSourceAgain()
        precondition(blockedDomain.savedMapping == nil && domainRestart.storedMapping(for: requestedWork, episode: requestedEpisode) == nil)
        // Return ownership to the original instance after the simulated restart changed disk authority.
        library.retryLoad()

        // No first-episode, another-line or quality fallback. Rejected saved identity remains blocking after restart.
        let missingEpisode = Data(String(decoding: catalogData, as: UTF8.self).replacingOccurrences(of: "/nid/2.html", with: "/nid/3.html").utf8)
        let missingLine = Data(String(decoding: catalogData, as: UTF8.self).replacingOccurrences(of: "/sid/1/nid/2.html", with: "/sid/2/nid/2.html").utf8)
        for changedCatalog in [missingEpisode, missingLine] {
            try library.saveMapping(confirmed)
            let transport = MappingTransport(catalog: changedCatalog, player: player)
            let missing = flow(transport, library: library)
            missing.playSaved()
            await idle(missing)
            precondition(missing.failure == .missingEpisode && missing.requiresReconfirmation && !missing.canRetry)
            let playerCalls = await transport.playerCalls
            precondition(playerCalls == 0 && missing.takeResolved() == nil)
            let restart = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
            let stillBlocked = flow(MappingTransport(catalog: catalogData, player: player), library: restart)
            precondition(stillBlocked.requiresReconfirmation && stillBlocked.failure == .missingEpisode)
        }
        var qualitySelection = confirmed.context.selection
        qualitySelection.qualityID = "1080p"
        let qualityMapping = ConfirmedSourceMapping(context: PlaybackContext(work: requestedWork, episode: requestedEpisode,
            selection: qualitySelection, configurationRevision: config.configurationRevision), sourceTitle: confirmed.sourceTitle)
        try library.saveMapping(qualityMapping)
        let missingQuality = flow(MappingTransport(catalog: catalogData, player: player), library: library)
        missingQuality.playSaved()
        await idle(missingQuality)
        precondition(missingQuality.failure == .missingEpisode && missingQuality.resolved == nil)

        // Wrong parser IDs invalidate saved identity. Paid/preview or wrong identity never save fresh selections.
        try library.saveMapping(confirmed)
        let wrong = flow(MappingTransport(catalog: catalogData, player: wrongPlayer), library: library)
        wrong.playSaved()
        await idle(wrong)
        precondition(wrong.failure == .missingEpisode && wrong.requiresReconfirmation && wrong.resolved == nil && !wrong.canRetry)
        for payload in [wrongPlayer, paidPlayer, previewPlayer] {
            try library.removeMapping(for: requestedWork, episode: requestedEpisode)
            let rejected = flow(MappingTransport(catalog: catalogData, player: payload), library: library)
            await confirm(rejected)
            precondition(rejected.failure == (payload == wrongPlayer ? .missingEpisode : .authenticationRequired))
            precondition(!rejected.canRetry && rejected.resolved == nil && rejected.catalog != nil)
            precondition(library.mapping(for: requestedWork, episode: requestedEpisode) == nil)
        }
        for status in [401, 403] { precondition(MobileSourceClient.responseFailure(statusCode: status) == .authenticationRequired) }
        for status in [408, 429, 500, 503] { precondition(MobileSourceClient.responseFailure(statusCode: status) == .network) }
        precondition(MobileSourceClient.responseFailure(statusCode: 415) == .unsupportedResponse)

        // Replacement during a saved catalogue fetch is observed before the player request.
        try library.saveMapping(confirmed)
        let changingTransport = MappingTransport(catalog: catalogData, player: player)
        await changingTransport.hold(.catalog)
        let changing = flow(changingTransport, library: library)
        changing.playSaved()
        while !(await changingTransport.waiting) { await Task.yield() }
        var replacement = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var replacementCatalog = replacement["catalog"] as! [String: Any]
        replacementCatalog["url"] = "https://www.fqdm.cc/catalog/{id}"
        replacement["catalog"] = replacementCatalog
        let replacementData = try JSONSerialization.data(withJSONObject: replacement)
        let replacementConfig = try SourceConfiguration.load(data: replacementData)
        try sources.apply(MobileSourceDraft(configuration: replacementConfig, data: replacementData))
        await changingTransport.release()
        await idle(changing)
        let changedPlayerCalls = await changingTransport.playerCalls
        precondition(changing.failure == .configurationChanged && changing.requiresReconfirmation && changedPlayerCalls == 0)
        try sources.apply(MobileSourceDraft(configuration: config, data: original))
        let changedRestart = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        precondition(flow(MappingTransport(catalog: catalogData, player: player), library: changedRestart).requiresReconfirmation)

        // Fresh resolve rechecks durable enablement/configuration; cancelled detached responses cannot save.
        for invalidation in 0..<3 {
            try library.removeMapping(for: requestedWork, episode: requestedEpisode)
            defaults.set(true, forKey: enabledKey)
            let transport = MappingTransport(catalog: catalogData, player: player)
            await transport.hold(.player)
            let candidate = flow(transport, library: library)
            candidate.open(work)
            await idle(candidate)
            candidate.play(candidate.catalog!.lines[0].episodes[0])
            while !(await transport.waiting) { await Task.yield() }
            switch invalidation {
            case 0: candidate.cancel()
            case 1: defaults.set(false, forKey: enabledKey)
            default: try sources.apply(MobileSourceDraft(configuration: replacementConfig, data: replacementData))
            }
            await transport.release()
            await idle(candidate)
            precondition(candidate.resolved == nil && library.mapping(for: requestedWork, episode: requestedEpisode) == nil)
            if invalidation == 1 { precondition(candidate.failure == .sourceDisabled) }
            if invalidation == 2 { precondition(candidate.failure == .configurationChanged) }
            try sources.apply(MobileSourceDraft(configuration: config, data: original))
        }
        defaults.set(true, forKey: enabledKey)
        let detachedTransport = MappingTransport(catalog: catalogData, player: player)
        await detachedTransport.hold(.catalog)
        try library.saveMapping(confirmed)
        var detached: MobileSourceFlow? = flow(detachedTransport, library: library)
        weak var detachedOwner = detached
        detached!.playSaved()
        while !(await detachedTransport.waiting) { await Task.yield() }
        detached = nil
        precondition(detachedOwner == nil) // The task must not retain a dismissed owner across an await.
        await detachedTransport.release()
        await Task.yield()
        let detachedPlayerCalls = await detachedTransport.playerCalls
        precondition(detachedPlayerCalls == 0)
        try library.removeMapping(for: requestedWork, episode: requestedEpisode)

        // Handoff reads durable configuration again even after parsing and mapping commit.
        let handoff = flow(MappingTransport(catalog: catalogData, player: player), library: library)
        await confirm(handoff)
        precondition(handoff.resolved != nil)
        try sources.apply(MobileSourceDraft(configuration: replacementConfig, data: replacementData))
        precondition(handoff.takeResolved() == nil && handoff.failure == .configurationChanged)
        precondition(library.mappingFailure(for: requestedWork, episode: requestedEpisode) == .configurationChanged)
        try sources.apply(MobileSourceDraft(configuration: config, data: original))

        // Malformed same-ID override must not reactivate its bundled shadow.
        try library.saveMapping(confirmed)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("Sources/fqdm.json"), options: .atomic)
        let malformed = flow(MappingTransport(catalog: catalogData, player: player), library: library)
        precondition(malformed.failure == .configurationChanged && malformed.requiresReconfirmation)
        precondition(!sources.sources.contains(where: { $0.id == config.id }))
        try sources.apply(MobileSourceDraft(configuration: config, data: original))

        // Save/remove failures preserve committed data and never expose successful playback.
        try library.removeMapping(for: requestedWork, episode: requestedEpisode)
        let staged = libraryURL.appendingPathExtension("staged")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let unsaved = flow(MappingTransport(catalog: catalogData, player: player), library: library)
        await confirm(unsaved)
        precondition(unsaved.storageFailure == .save && unsaved.failure == nil && unsaved.takeResolved() == nil)
        precondition(library.mapping(for: requestedWork, episode: requestedEpisode) == nil)
        let failedSaveRestart = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        precondition(failedSaveRestart.mapping(for: requestedWork, episode: requestedEpisode) == nil)
        try FileManager.default.removeItem(at: staged)
        try library.saveMapping(confirmed)
        let removeFailure = flow(MappingTransport(catalog: missingEpisode, player: player), library: library)
        removeFailure.playSaved()
        await idle(removeFailure)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        removeFailure.chooseSourceAgain()
        precondition(removeFailure.storageFailure == .remove && removeFailure.failure == .missingEpisode)
        precondition(removeFailure.savedMapping == confirmed && removeFailure.requiresReconfirmation)
        let failedRemoveRestart = MobileLibrary(file: legacyURL, libraryFile: libraryURL)
        precondition(failedRemoveRestart.storedMapping(for: requestedWork, episode: requestedEpisode) == confirmed)
        precondition(failedRemoveRestart.mappingFailure(for: requestedWork, episode: requestedEpisode) == .missingEpisode)
        print("PASS: production mapping save/restart/reuse, exact identity/line/quality, durable invalidation, current source authority, disable/re-enable, parser errors, cancellation and transactional writes")
    }
}

extension SourceRegression {
    @MainActor static func mobileContracts(config: SourceConfiguration, client: MobileSourceClient,
                                          work: MobileSourceWork, catalog: MobileSourceCatalog,
                                          episode: MobileSourceEpisode, player: Data) async throws {
        let context = try client.playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil)
        precondition(context.work.bangumiID == nil && context.episode.bangumiID == nil)
        precondition(context.work == .source(sourceID: config.id, workID: "42"))
        precondition(context.episode == .source(sourceID: config.id, workID: "42", episodeID: "2"))
        precondition(context.work != .source(sourceID: "another-source", workID: "42"))
        precondition(context.work != .source(sourceID: config.id, workID: "99"))
        precondition(context.episode != .source(sourceID: config.id, workID: "42", episodeID: "1"))
        precondition(context.episode != .source(sourceID: config.id, workID: "99", episodeID: "2"))
        precondition(PlaybackWorkIdentity.bangumi(101) != .bangumi(102))
        precondition(PlaybackEpisodeIdentity.bangumi(901, type: 0, sort: 1) != .bangumi(902, type: 1, sort: 1))
        precondition(PlaybackWorkIdentity.source(sourceID: "a|b", workID: "c") != .source(sourceID: "a", workID: "b|c"))

        let disabled = MobileSourceFlow(client: MobileSourceClient(configuration: config) { _ in
            preconditionFailure("A disabled source must not perform a request")
        })
        disabled.search("Fixture")
        precondition(disabled.failure == .sourceDisabled && !disabled.busy && disabled.resolved == nil)
        disabled.open(work)
        precondition(disabled.failure == .sourceDisabled)
        disabled.openPage(work.item.pageURL)
        precondition(disabled.failure == .sourceDisabled)
        disabled.play(episode)
        precondition(disabled.failure == .sourceDisabled)

        let missing = MobileSourceFlow(client: client, enabled: true)
        missing.play(episode)
        precondition(missing.failure == .missingEpisode)
        let empty = MobileSourceFlow(client: MobileSourceClient(configuration: config) { _ in
            Data("<html><body>No results</body></html>".utf8)
        }, enabled: true)
        empty.search("missing")
        while empty.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(empty.failure == .noCandidates && !empty.canRetry)

        let challenge = MobileSourceFlow(client: MobileSourceClient(configuration: config) { _ in
            Data("<form id='challenge-form'></form>".utf8)
        }, enabled: true)
        challenge.search("Fixture")
        while challenge.busy { try await Task.sleep(for: .milliseconds(10)) }
        precondition(challenge.failure == .authenticationRequired && !challenge.canRetry)
        precondition(MobileSourceClient.failure(for: CancellationError()) == .cancelled)
        precondition(MobileSourceClient.failure(for: URLError(.timedOut)) == .network)
        precondition(MobileSourceClient.failure(for: SourceConfiguration.ConfigurationError.invalidMedia) == .unsupportedResponse)

        let delayed = MobileSourceClient(configuration: config) { url in
            if url.path.contains("detail") {
                return Data("<div class='module-info-heading'><h1>Fixture</h1></div><div class='module-play-list'><a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/1/nid/2.html'>Episode 2</a></div>".utf8)
            }
            // Deliberately ignore cancellation as a transport can finish after its owner disappears.
            try? await Task.sleep(for: .milliseconds(100))
            return player
        }
        for invalidation in 0..<4 {
            let flow = MobileSourceFlow(client: delayed, enabled: true)
            flow.open(work)
            while flow.busy { try await Task.sleep(for: .milliseconds(10)) }
            flow.play(flow.catalog!.lines[0].episodes[0])
            try await Task.sleep(for: .milliseconds(10))
            switch invalidation {
            case 0: flow.cancel()
            case 1: flow.updateAccess(enabled: false, configurationRevision: config.configurationRevision)
            case 2: flow.updateAccess(enabled: true, configurationRevision: "changed")
            default: flow.open(work)
            }
            try await Task.sleep(for: .milliseconds(150))
            precondition(flow.resolved == nil && !flow.busy)
            precondition(flow.takeResolved() == nil)
        }
        // The result can become unauthorized between resolution and UI presentation.
        for changeRevision in [false, true] {
            let flow = MobileSourceFlow(client: client, enabled: true)
            flow.open(work)
            while flow.busy { try await Task.sleep(for: .milliseconds(10)) }
            flow.play(episode)
            while flow.busy { try await Task.sleep(for: .milliseconds(10)) }
            precondition(flow.resolved != nil)
            flow.updateAccess(enabled: changeRevision, configurationRevision: changeRevision ? "changed" : config.configurationRevision)
            precondition(flow.takeResolved() == nil)
            precondition(flow.failure == (changeRevision ? .configurationChanged : .sourceDisabled))
        }
        print("PASS: full requested Bangumi/source context, distinct season/source/episode identity, disabled invocation, classified failures and stale/cancelled one-shot handoff")
    }

    @MainActor static func configurationFiles(root: URL) async throws {
        let original = try Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let config = try MobileSourceLibrary.validate(original)
        var otherObject = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        var allCapabilities = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        allCapabilities["capabilities"] = config.capabilities.union([.quality]).map(\.rawValue)
        let declared = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: allCapabilities))
        let effective = declared.effectiveCapabilities(on: .iOS)
        let declaredClient = MobileSourceClient(configuration: declared) { _ in
            preconditionFailure("Unsupported capability must be rejected before fetching")
        }
        for capability in [SourceCapability.iina, .jsPlayer, .danmaku, .download, .browse, .quality] {
            precondition(!effective.contains(capability))
            await rejects { try declaredClient.require(capability) }
        }
        for unsupported in [SourceCapability.jsPlayer, .danmaku, .browse] {
            var invalid = allCapabilities
            invalid["capabilities"] = config.capabilities.union([unsupported]).map(\.rawValue)
            await rejects { _ = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: invalid)) }
        }
        var noSearchConfiguration = allCapabilities
        noSearchConfiguration["capabilities"] = config.capabilities.subtracting([.search]).map(\.rawValue)
        noSearchConfiguration.removeValue(forKey: "search")
        let noSearchClient = MobileSourceClient(configuration: try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: noSearchConfiguration))) { _ in
            preconditionFailure("An undeclared search capability must not fetch")
        }
        await rejects { _ = try await noSearchClient.search("Fixture") }
        otherObject["id"] = "second-source"
        otherObject["name"] = "Second source"
        let other = try JSONSerialization.data(withJSONObject: otherObject)
        let manifest = Data(#"{"version":1,"sources":["second.json","fqdm.json"]}"#.utf8)
        let loaded = try MobileSourceLibrary.loadManifest(manifest) { $0 == "fqdm.json" ? original : other }
        precondition(loaded.map(\.id) == ["second-source", "fqdm"])
        for invalid in [#"{"version":2,"sources":[]}"#, #"{"version":1,"sources":["../fqdm.json"]}"#, #"{"version":1,"sources":["fqdm.json","fqdm.json"]}"#] {
            await rejects { _ = try MobileSourceLibrary.loadManifest(Data(invalid.utf8)) { _ in original } }
        }
        await rejects { _ = try MobileSourceLibrary.loadManifest(manifest) { _ in original } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("input.json")
        try other.write(to: input)
        let stored = directory.appendingPathComponent("sources")
        let library = MobileSourceLibrary(directory: stored, bundled: { [config] })
        let draft = try library.prepare(input)
        precondition(!library.replaces(draft))
        try library.apply(draft)
        precondition(library.sources.map(\.id) == ["fqdm", "second-source"])
        let restored = MobileSourceLibrary(directory: stored, bundled: { [config] })
        precondition(restored.sources.last?.configuration.name == "Second source")
        precondition(restored.replaces(draft))
        otherObject["name"] = "Updated source"
        let updatedData = try JSONSerialization.data(withJSONObject: otherObject)
        try updatedData.write(to: input)
        try restored.apply(restored.prepare(input))
        let replaced = MobileSourceLibrary(directory: stored, bundled: { [config] })
        precondition(replaced.sources.last?.configuration.name == "Updated source")
        let before = try Data(contentsOf: stored.appendingPathComponent("second-source.json"))
        let invalidDraft = MobileSourceDraft(configuration: draft.configuration, data: Data("broken".utf8))
        await rejects { _ = try restored.apply(invalidDraft) }
        let after = try Data(contentsOf: stored.appendingPathComponent("second-source.json"))
        precondition(before == after)
        let brokenURL = stored.appendingPathComponent("broken.json")
        try Data("broken".utf8).write(to: brokenURL)
        restored.reload()
        precondition(restored.sources.count == 2 && restored.issues == ["broken.json"])
        let brokenContents = try String(contentsOf: brokenURL, encoding: .utf8)
        precondition(brokenContents == "broken")
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("preserve".utf8).write(to: blocked)
        let inaccessible = MobileSourceLibrary(directory: blocked, bundled: { [config] })
        await rejects { _ = try inaccessible.apply(draft) }
        let blockedContents = try String(contentsOf: blocked, encoding: .utf8)
        precondition(blockedContents == "preserve")

        let archiveData = try Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))
        let archive = try MobileSourceLibrary.validate(archiveData)
        let jsonSearch = Data(#"{"response":{"numFound":21,"docs":[{"identifier":"public-film","title":"A <b>film</b>"}]}}"#.utf8)
        let jsonCatalog = Data(#"{"metadata":{"title":"A film"},"files":[{"name":"video one.mp4"},{"name":"subtitles.srt"},{"name":"video-two.mp4"}]}"#.utf8)
        let archiveClient = MobileSourceClient(configuration: archive) { url in
            if url.path == "/advancedsearch.php" { return jsonSearch }
            if url.path == "/metadata/public-film" { return jsonCatalog }
            throw MobileSourceError.invalidSelection
        }
        let archivePage = try await archiveClient.search("film")
        precondition(archivePage.works.first?.title == "A film" && archivePage.nextPage == 2)
        let archiveList = try await archiveClient.catalog(archivePage.works[0])
        precondition(archiveList.lines[0].episodes.count == 2)
        let archiveEpisode = archiveList.lines[0].episodes[0]
        precondition(archiveEpisode.identity == "video one.mp4")
        let archiveMedia = try await archiveClient.resolve(archiveEpisode, in: archiveList)
        precondition(archiveMedia.path == "/download/public-film/video one.mp4")
        let archiveContext = try archiveClient.playbackContext(archiveEpisode, in: archiveList, requestedWork: nil, requestedEpisode: nil)
        precondition(archiveContext.work == .source(sourceID: "internet-archive", workID: "public-film"))
        precondition(archiveContext.episode == .source(sourceID: "internet-archive", workID: "public-film", episodeID: "video one.mp4"))
        precondition(archiveContext.selection.episode == archiveEpisode.item)
        precondition(archiveContext.configurationRevision == archive.configurationRevision)
        let anotherFileContext = try archiveClient.playbackContext(archiveList.lines[0].episodes[1], in: archiveList, requestedWork: nil, requestedEpisode: nil)
        precondition(anotherFileContext.episode != archiveContext.episode)
        let fileLegacy = directory.appendingPathComponent("file-library/favorites.json")
        let fileLibrary = MobileLibrary(file: fileLegacy)
        let fileFlow = MobileSourceFlow(client: archiveClient, requestedWork: archiveContext.work,
            requestedEpisode: archiveContext.episode, enabled: true, library: fileLibrary)
        fileFlow.open(archivePage.works[0])
        await idle(fileFlow)
        fileFlow.play(fileFlow.catalog!.lines[0].episodes[0])
        await idle(fileFlow)
        precondition(fileFlow.takeResolved()?.url == archiveMedia)
        let reorderedFiles = Data(#"{"metadata":{"title":"Renamed film"},"files":[{"name":"video-two.mp4"},{"name":"video one.mp4"}]}"#.utf8)
        let reorderedClient = MobileSourceClient(configuration: archive) { _ in reorderedFiles }
        let fileRestart = MobileLibrary(file: fileLegacy)
        let savedFile = MobileSourceFlow(client: reorderedClient, requestedWork: archiveContext.work,
            requestedEpisode: archiveContext.episode, enabled: true, library: fileRestart)
        savedFile.playSaved()
        await idle(savedFile)
        precondition(savedFile.takeResolved()?.url == archiveMedia) // File identity wins over changed positional numbering.
        await rejects { _ = try await archiveClient.catalog(MobileSourceWork(item: SourceItemRef(sourceID: "wrong", pageURL: archivePage.works[0].item.pageURL, kind: .work), title: "Wrong")) }

        var payloadConfig = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        payloadConfig["search"] = ["url": "https://www.fqdm.cc/search", "format": "json", "queryParameter": "q", "pageParameter": "page", "firstPage": 0, "rowsPerPage": 2, "jsonResultsPath": "results", "jsonTitlePath": "title", "jsonIdentifierPath": "id", "jsonTotalPath": "total"] as [String: Any]
        payloadConfig["catalog"] = ["url": "https://www.fqdm.cc/catalog/{id}", "format": "json", "jsonTitlePath": "title", "jsonEntriesPath": "episodes", "jsonEpisodeTitlePath": "title", "jsonEpisodeURLPath": "url", "jsonLineNumberPath": "line", "jsonLineTitlePath": "label", "jsonEpisodeNumberPath": "number"]
        var player = payloadConfig["player"] as! [String: Any]
        player["format"] = "json"; player["payloadPattern"] = "data.player"
        payloadConfig["player"] = player
        let jsonConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: payloadConfig))
        let payloadClient = MobileSourceClient(configuration: jsonConfig) { url in
            if url.path == "/search" {
                precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value == "0")
                return Data(#"{"results":[{"id":42,"title":"JSON show"}],"total":1}"#.utf8)
            }
            if url.path == "/catalog/42" {
                return Data(#"{"title":"JSON show","episodes":[{"title":"Episode 7","url":"https://www.fqdm.cc/index.php/vod/play/id/42/sid/2/nid/7.html","line":2,"label":"Line 2","number":7}]}"#.utf8)
            }
            return Data(#"{"data":{"player":{"id":"42","sid":2,"nid":7,"points":0,"trysee":0,"encrypt":0,"url":"https://media.example.test/video.mp4"}}}"#.utf8)
        }
        let jsonPage = try await payloadClient.search("show")
        let jsonList = try await payloadClient.catalog(jsonPage.works[0])
        precondition(jsonList.lines[0].id == 2 && jsonList.lines[0].episodes[0].number == 7)
        let resolved = try await payloadClient.resolve(jsonList.lines[0].episodes[0], in: jsonList)
        precondition(resolved.host == "media.example.test")
        let jsonContext = try payloadClient.playbackContext(jsonList.lines[0].episodes[0], in: jsonList,
            requestedWork: .bangumi(202), requestedEpisode: .bangumi(902, type: 0, sort: 2))
        precondition(jsonContext.selection.lineID == "2" && jsonContext.episode.bangumiID == 902)
        precondition(jsonContext.episode.sort == 2 && jsonContext.configurationRevision == jsonConfig.configurationRevision)
        var htmlFilesObject = try JSONSerialization.jsonObject(with: archiveData) as! [String: Any]
        htmlFilesObject["catalog"] = ["url": "https://archive.org/details/{id}", "format": "html", "titleSelector": "h1", "panelSelector": ".files", "episodeSelector": "a", "episodeURLAttribute": "href"]
        let htmlFilesConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: htmlFilesObject))
        let htmlFiles = MobileSourceClient(configuration: htmlFilesConfig) { _ in
            Data("<h1>Files</h1><div class='files'><a href='/details/public-film?file=video.mp4'>Video</a></div>".utf8)
        }
        let htmlFileCatalog = try await htmlFiles.catalog(archivePage.works[0])
        precondition(htmlFileCatalog.lines[0].episodes[0].number == 1)
        let fileMedia = try await htmlFiles.resolve(htmlFileCatalog.lines[0].episodes[0], in: htmlFileCatalog)
        precondition(fileMedia.path == "/download/public-film/video.mp4")
        let noSearch = MobileSourceClient(configuration: config)
        let manualWork = try noSearch.work(at: "https://www.fqdm.cc/index.php/vod/detail/id/42.html")
        precondition(manualWork.item.kind == .work)
        await rejects { _ = try noSearch.work(at: "https://evil.example/index.php/vod/detail/id/42.html") }
        print("PASS: ordered manifests, file import/restart/replace protection, corrupt-file isolation, JSON search/catalog/player, file identity/template resolution and source isolation")
    }
}

extension SourceRegression {
    @MainActor static func nextEpisodeContracts(config: SourceConfiguration, work: MobileSourceWork) async throws {
        func link(_ line: Int, _ episode: Int) -> String {
            "<a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/\(line)/nid/\(episode).html'>Episode \(episode)</a>"
        }
        let markup = "<div class='module-info-heading'><h1>Fixture</h1></div>" +
            "<div class='module-play-list'>\(link(1, 2))\(link(1, 3))</div>" +
            "<div class='module-play-list'>\(link(2, 1))\(link(2, 2))</div>"
        let payload = Data(#"<script>var player_aaaa={"id":"42","sid":1,"nid":3,"points":0,"trysee":0,"encrypt":0,"url":"https://media.example.test/third.mp4"};</script>"#.utf8)
        let transport = MappingTransport(catalog: Data(markup.utf8), player: payload)
        let client = MobileSourceClient(configuration: config) { try Task.checkCancellation(); return await transport.fetch($0) }
        let catalog = try await client.catalog(work)
        let current = catalog.lines[0].episodes[0], third = catalog.lines[0].episodes[1]
        let context = try client.playbackContext(current, in: catalog,
            requestedWork: .bangumi(4242), requestedEpisode: .bangumi(4202, type: 0, sort: 2))
        let following = try client.nextEpisode(after: context.selection, in: catalog)
        precondition(following == third)
        let last = try client.playbackContext(third, in: catalog, requestedWork: nil, requestedEpisode: nil)
        let end = try client.nextEpisode(after: last.selection, in: catalog)
        precondition(end == nil) // Never enters line 2.
        var enabled = true
        var revision = config.configurationRevision
        let continuation = MobileSourceContinuation(client: client, authority: {
            guard enabled else { throw PlaybackFailure.sourceDisabled }
            return revision
        })
        let result = try await continuation.resolve(after: context, next: true)!
        precondition(result.context.work == context.work && result.context.episode != context.episode)
        precondition(result.context.episode.bangumiID == nil) // A source ordinal is not the next Bangumi episode ID.
        precondition(result.context.selection.episode == third.item && result.context.selection.lineID == "1")
        precondition(result.url.lastPathComponent == "third.mp4")

        let missing = MobileSourceCatalog(work: catalog.work, lines: [
            MobileSourceLine(id: 1, title: "line", episodes: [third])])
        await rejects { _ = try client.nextEpisode(after: context.selection, in: missing) }
        let duplicate = MobileSourceCatalog(work: catalog.work, lines: [
            MobileSourceLine(id: 1, title: "line", episodes: [current, third, third])])
        await rejects { _ = try client.nextEpisode(after: context.selection, in: duplicate) }
        let fourthItem = SourceItemRef(sourceID: "fqdm",
            pageURL: "https://www.fqdm.cc/index.php/vod/play/id/42/sid/1/nid/4.html", kind: .episode)
        let fourth = MobileSourceEpisode(item: fourthItem, title: "four", line: 1, number: 4)
        let gap = MobileSourceCatalog(work: catalog.work, lines: [
            MobileSourceLine(id: 1, title: "line", episodes: [current, fourth])])
        await rejects { _ = try client.nextEpisode(after: context.selection, in: gap) }
        var changedQuality = third
        changedQuality.qualityID = "different"
        let qualities = MobileSourceCatalog(work: catalog.work, lines: [
            MobileSourceLine(id: 1, title: "line", episodes: [current, changedQuality])])
        do {
            _ = try client.nextEpisode(after: context.selection, in: qualities)
            fatalError("Next silently changed quality")
        } catch MobileNextEpisodeError.qualityUnavailable {}
        var live = context.selection
        live.classification = MediaClassification(kind: .live, provenance: "fixture")
        await rejects { _ = try client.nextEpisode(after: live, in: catalog) }

        for endpoint in [MappingTransport.Endpoint.catalog, .player] {
            await transport.hold(endpoint)
            let pending = Task { try await continuation.resolve(after: context, next: true) }
            while !(await transport.waiting) { await Task.yield() }
            enabled = false
            await transport.release()
            do { _ = try await pending.value; fatalError("Disabled source handed off next episode") }
            catch PlaybackFailure.sourceDisabled {}
            enabled = true
        }
        await transport.hold(.player)
        let changed = Task { try await continuation.resolve(after: context, next: true) }
        while !(await transport.waiting) { await Task.yield() }
        revision = "changed"
        await transport.release()
        do { _ = try await changed.value; fatalError("Changed configuration handed off next episode") }
        catch PlaybackFailure.configurationChanged {}
        revision = config.configurationRevision

        await transport.hold(.player)
        let cancelled = Task { try await continuation.resolve(after: context, next: true) }
        while !(await transport.waiting) { await Task.yield() }
        cancelled.cancel()
        await transport.release()
        do { _ = try await cancelled.value; fatalError("Cancelled next episode handed off") }
        catch is CancellationError {}
        print("PASS: same-line next, no group/quality fallback, missing/duplicate/live rejection, exact new identity and in-flight authority/cancellation")
    }
}
