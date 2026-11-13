import SourceCore
import SourceRuntime
import Foundation
import CryptoKit

struct MobileSourceWork: Identifiable, Hashable, Sendable {
    let item: SourceItemRef
    let title: String
    var id: String { PlaybackWorkIdentity.source(item).localID }
}

struct MobileSourceEpisode: Identifiable, Hashable, Sendable {
    let item: SourceItemRef
    let title: String
    let line: Int
    let number: Int
    var identity: String? = nil
    var mediaPath: String? = nil
    var qualityID: String? = nil
    var id: String {
        let base = PlaybackEpisodeIdentity.source(sourceID: item.sourceID, workID: String(line), episodeID: item.pageURL).localID
        return qualityID.map { base + "|quality:\($0.utf8.count):" + $0 } ?? base
    }
    var runtime: RuntimeEpisode {
        RuntimeEpisode(item: item, title: title, line: line, number: number,
                       identity: identity, mediaPath: mediaPath, qualityID: qualityID)
    }
}

struct MobileSourceLine: Identifiable, Sendable {
    let id: Int
    let title: String
    let episodes: [MobileSourceEpisode]
}

struct MobileSourceCatalog: Sendable {
    let work: MobileSourceWork
    let lines: [MobileSourceLine]
    var runtime: RuntimeCatalog {
        RuntimeCatalog(work: RuntimeWork(item: work.item, title: work.title), lines: lines.map {
            RuntimeLine(id: $0.id, title: $0.title, episodes: $0.episodes.map(\.runtime))
        })
    }
}

struct MobileSourcePage: Sendable {
    let works: [MobileSourceWork]
    let nextPage: Int?
}

enum MobileSourceError: Error, Equatable { case unavailable, invalidResponse, invalidSelection, inactiveWebSelector, nativeConflict }

/// Mobile owns presentation and durable choices; source parsing and HTTP belong to SourceRuntime.
struct MobileSourceClient: Sendable {
    let source: RuntimeSource
    let search: NativeSearchSource?
    private let fetch: SourceHTTPTransport.Fetch?
    private let nativeClient: NativeSourceClient?

    init(source: RuntimeSource, search: NativeSearchSource? = nil, fetch: SourceHTTPTransport.Fetch? = nil) {
        self.source = source
        self.search = search
        self.fetch = fetch
        if case .native(let id) = source { nativeClient = NativeSourceClient(sourceID: id, fetch: fetch) }
        else { nativeClient = nil }
    }
    var capabilities: Set<SourceCapability> {
        var result = source.effectiveCapabilities(on: .iOS)
        if search != nil { result.insert(.search) }
        else { result.remove(.search) }
        return result
    }

    static func make(source: RuntimeSource, search: NativeSearchSource? = nil) -> Self {
        #if DEBUG
        if SourceFixtures.enabled {
            let transport = SourceFixtureTransport()
            return Self(source: source, search: search, fetch: { request in
                guard let url = request.url else { throw MobileSourceError.invalidSelection }
                return SourceHTTPResponse(data: try await transport.fetch(url), url: url, statusCode: 200)
            })
        }
        #endif
        return Self(source: source, search: search)
    }

    func require(_ capability: SourceCapability) throws {
        guard capabilities.contains(capability) else { throw PlaybackFailure.unsupportedResponse }
    }

    static func failure(for error: Error) -> PlaybackFailure {
        if let error = error as? SourceSearchError {
            switch error {
            case .transport: return .network
            case .httpStatus(let status): return responseFailure(statusCode: status) ?? .unsupportedResponse
            case .malformedResponse: return .searchStructure
            case .invalidConfiguration: return .unsupportedResponse
            }
        }
        if let failure = error as? PlaybackFailure { return failure }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .userAuthenticationRequired, .userCancelledAuthentication: return .authenticationRequired
            default: return .network
            }
        }
        if let error = error as? MobileSourceError {
            switch error {
            case .invalidSelection: return .missingEpisode
            case .unavailable, .invalidResponse, .inactiveWebSelector, .nativeConflict: return .unsupportedResponse
            }
        }
        return .unsupportedResponse
    }

    static func responseFailure(statusCode: Int) -> PlaybackFailure? {
        if statusCode == 401 { return .authenticationRequired }
        if statusCode == 403 { return .httpForbidden }
        if (300..<400).contains(statusCode) { return .sourceRedirect }
        if statusCode == 408 || statusCode == 429 || (500..<600).contains(statusCode) { return .network }
        return (200..<300).contains(statusCode) ? nil : .unsupportedResponse
    }

    func playbackContext(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog,
                         requestedWork: PlaybackWorkIdentity?, requestedEpisode: PlaybackEpisodeIdentity?) throws -> PlaybackContext {
        guard catalog.work.item.sourceID == source.id, episode.item.sourceID == source.id,
              catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else {
            throw PlaybackFailure.missingEpisode
        }
        if catalog.work.item.kind == .video {
            guard source.id == "hanime1", episode.item == catalog.work.item, episode.line == 0,
                  episode.qualityID.map(ConfirmedSourceMapping.safeLabel) == true else { throw PlaybackFailure.missingEpisode }
        }
        let selection = try source.mappingSelection(PlayableSelection(item: catalog.work.item,
            episode: episode.item, lineID: String(episode.line), qualityID: episode.qualityID,
            classification: source.classification))
        let workID: String
        let episodeID: String
        if let configuration = source.configured, configuration.version != 4 {
            let work = try configuration.parts(selection.item.pageURL)
            let parts = try configuration.parts(selection.episode!.pageURL)
            guard work.id == parts.id, let identity = parts.episodeIdentity else { throw PlaybackFailure.missingEpisode }
            workID = work.id
            episodeID = identity
        } else {
            func identity(_ raw: String) -> String { SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined() }
            workID = identity(selection.item.pageURL)
            episodeID = identity(selection.episode!.pageURL)
        }
        return PlaybackContext(work: requestedWork ?? .source(sourceID: source.id, workID: workID),
            episode: requestedEpisode ?? .source(sourceID: source.id, workID: workID, episodeID: episodeID),
            selection: selection, configurationRevision: source.configurationRevision)
    }

    /// A saved choice names one leaf, line and quality; catalogue order is never a fallback.
    func episode(matching selection: PlayableSelection, in catalog: MobileSourceCatalog) throws -> MobileSourceEpisode {
        let saved = try source.mappingSelection(selection)
        let matches = try catalog.lines.flatMap(\.episodes).filter { episode in
            let current = try playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil).selection
            return current.item == saved.item && current.episode == saved.episode &&
                current.lineID == saved.lineID && current.qualityID == saved.qualityID
        }
        guard matches.count == 1, let episode = matches.first else { throw PlaybackFailure.missingEpisode }
        return episode
    }

    /// A dynamic stream key is fetched only for the selected episode, never for an entire catalog.
    func playbackOptions(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog) async throws -> [MobileSourceEpisode] {
        guard catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else {
            throw PlaybackFailure.missingEpisode
        }
        guard let nativeClient else { return [episode] }
        let options = try await nativeClient.playbackOptions(episode.runtime, in: catalog.runtime)
        guard !options.isEmpty else { throw PlaybackFailure.missingMediaQuality }
        return options.map { MobileSourceEpisode(item: $0.item, title: $0.title, line: $0.line, number: $0.number,
            identity: $0.identity, mediaPath: $0.mediaPath, qualityID: $0.qualityID) }
    }

    private var hasDynamicOptions: Bool { source.id == "senfun" || source.id == "dilidili" }

    func selecting(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog) throws -> MobileSourceCatalog {
        guard hasDynamicOptions else {
            guard catalog.lines.contains(where: { $0.id == episode.line && $0.episodes.contains(episode) }) else { throw PlaybackFailure.missingEpisode }
            return catalog
        }
        var matched = 0
        let lines = catalog.lines.map { line in
            MobileSourceLine(id: line.id, title: line.title, episodes: line.episodes.map { base in
                guard base.item == episode.item, base.line == episode.line, base.number == episode.number,
                      base.identity == episode.identity, base.mediaPath == episode.mediaPath else { return base }
                matched += 1
                return episode
            })
        }
        guard matched == 1 else { throw PlaybackFailure.missingEpisode }
        return MobileSourceCatalog(work: catalog.work, lines: lines)
    }

    func selectedEpisode(matching selection: PlayableSelection, in catalog: MobileSourceCatalog) async throws -> (episode: MobileSourceEpisode, catalog: MobileSourceCatalog) {
        guard hasDynamicOptions else { return (try episode(matching: selection, in: catalog), catalog) }
        let saved = try source.mappingSelection(selection)
        let bases = catalog.lines.flatMap(\.episodes).filter {
            $0.item == saved.episode && String($0.line) == saved.lineID
        }
        guard bases.count == 1, let base = bases.first else { throw PlaybackFailure.missingEpisode }
        let options = try await playbackOptions(base, in: catalog)
        let matches = options.filter { $0.qualityID == saved.qualityID }
        guard matches.count == 1, let selected = matches.first else { throw MobileNextEpisodeError.qualityUnavailable }
        let bound = try selecting(selected, in: catalog)
        return (try episode(matching: saved, in: bound), bound)
    }

    func nextEpisode(after selection: PlayableSelection, in catalog: MobileSourceCatalog) throws -> MobileSourceEpisode? {
        guard selection.item.kind == .work, selection.classification.kind != .live,
              selection.torrent == nil else { throw PlaybackFailure.unsupportedResponse }
        let current = try episode(matching: selection, in: catalog)
        let groups = catalog.lines.filter { $0.id == current.line }
        guard groups.count == 1, let group = groups.first,
              let index = group.episodes.firstIndex(of: current) else { throw PlaybackFailure.missingEpisode }
        guard index + 1 < group.episodes.count else { return nil }
        let next = group.episodes[index + 1]
        guard next.item != current.item, next.line == current.line,
              group.episodes.filter({ $0.number == next.number }).count == 1 else { throw PlaybackFailure.missingEpisode }
        if let config = source.configured,
           config.route.episodeGroup != nil || config.catalog.jsonEpisodeNumberPath != nil {
            guard current.number < Int.max, next.number == current.number + 1 else { throw PlaybackFailure.missingEpisode }
        }
        guard hasDynamicOptions || next.qualityID == selection.qualityID else { throw MobileNextEpisodeError.qualityUnavailable }
        _ = try playbackContext(next, in: catalog, requestedWork: nil, requestedEpisode: nil)
        return next
    }

    func work(at address: String) throws -> MobileSourceWork {
        try require(.information)
        let item = try source.item(address.trimmingCharacters(in: .whitespacesAndNewlines))
        guard item.kind == .work || (source.id == "hanime1" && item.kind == .video) else { throw MobileSourceError.invalidSelection }
        return MobileSourceWork(item: item, title: source.name)
    }

    func search(_ keyword: String, page: Int = 1) async throws -> MobileSourcePage {
        try require(.search)
        guard let metadata = search else { throw MobileSourceError.unavailable }
        if let configuration = source.configured, configuration.version == 4 {
            let result = try await StaticWebSourceClient(configuration: configuration, fetch: fetch)
                .search(query: keyword, page: page, searchOverride: metadata.search)
            return MobileSourcePage(works: result.results.map { MobileSourceWork(item: $0.item, title: $0.title) }, nextPage: result.nextPage)
        }
        let source = source
        let result = try await SourceSearchExecutor.search(query: keyword, page: page, spec: metadata.search,
            allowedHosts: Set(metadata.hosts.map { $0.lowercased() }), resultURLTemplate: metadata.resultURLTemplate,
            allowLegacyArrayQueryParameters: source.configured.map { $0.version < 3 } ?? false,
            classification: { _ in source.classification }, fetch: fetch,
            item: { try? source.item($0) })
        return MobileSourcePage(works: result.results.map { MobileSourceWork(item: $0.item, title: $0.title) }, nextPage: result.nextPage)
    }

    func catalog(_ work: MobileSourceWork) async throws -> MobileSourceCatalog {
        if work.item.kind == .work { try require(.episodes) }
        else { try require(.information) }
        guard work.item.sourceID == source.id,
              work.item.kind == .work || (source.id == "hanime1" && work.item.kind == .video) else { throw MobileSourceError.invalidSelection }
        let work = RuntimeWork(item: work.item, title: work.title)
        let result: RuntimeCatalog
        switch source {
        case .native:
            guard let nativeClient else { throw MobileSourceError.unavailable }
            result = try await nativeClient.catalog(work)
        case .configured(let configuration): result = try await ConfiguredSourceClient(configuration: configuration, fetch: fetch).catalog(work)
        }
        return MobileSourceCatalog(work: MobileSourceWork(item: result.work.item, title: result.work.title), lines: result.lines.map { line in
            MobileSourceLine(id: line.id, title: line.title, episodes: line.episodes.map {
                MobileSourceEpisode(item: $0.item, title: $0.title, line: $0.line, number: $0.number,
                    identity: $0.identity, mediaPath: $0.mediaPath, qualityID: $0.qualityID)
            })
        })
    }

    func resolve(_ episode: MobileSourceEpisode, in catalog: MobileSourceCatalog) async throws -> URL {
        try require(.resolve)
        if catalog.lines.count > 1 { try require(.lines) }
        if source.configured != nil && episode.qualityID != nil { try require(.quality) }
        _ = try playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil)
        switch source {
        case .native:
            guard let nativeClient else { throw MobileSourceError.unavailable }
            return try await nativeClient.resolve(episode.runtime, in: catalog.runtime)
        case .configured(let configuration): return try await ConfiguredSourceClient(configuration: configuration, fetch: fetch).resolve(episode.runtime, in: catalog.runtime)
        }
    }
}
