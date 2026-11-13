import SourceCore
import SourceRuntime
import Foundation
import Observation

struct MobileResolvedPlayback: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let context: PlaybackContext
}

/// One owned task and generation guard cover search, fresh saved-catalogue lookup and resolution.
@MainActor @Observable
final class MobileSourceFlow {
    enum StorageFailure: Equatable { case unavailable, save, remove, invalidate }
    private(set) var results: [MobileSourceWork] = []
    private(set) var catalog: MobileSourceCatalog?
    private(set) var playbackOptions: [MobileSourceEpisode] = []
    private var optionsCatalog: MobileSourceCatalog?
    private(set) var nextPage: Int?
    private(set) var busy = false
    private(set) var failure: PlaybackFailure?
    private(set) var storageFailure: StorageFailure?
    private(set) var savedMapping: ConfirmedSourceMapping?
    private(set) var requiresReconfirmation = false
    var failed: Bool { failure != nil || storageFailure != nil }
    private(set) var searched = false
    private(set) var resolved: MobileResolvedPlayback?
    private let client: MobileSourceClient
    private let requestedWork: PlaybackWorkIdentity?
    private let requestedEpisode: PlaybackEpisodeIdentity?
    private let library: MobileLibrary?
    private let authority: (() throws -> String)?
    private let searchAuthority: (() throws -> String)?
    private let searchRevision: String
    private var enabled: Bool
    private var configurationRevision: String
    private var lastQuery = ""
    private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    private var lastAction: Action?
    var canRetry: Bool { lastAction != nil && failure == .network && !requiresReconfirmation && storageFailure == nil }
    var canPlaySaved: Bool { savedMapping != nil && !requiresReconfirmation && !busy && storageFailure == nil && (failure == nil || failure == .network) }
    private enum Action {
        case search(String, Int), catalog(MobileSourceWork)
        case resolve(MobileSourceEpisode, MobileSourceCatalog), reuse(ConfirmedSourceMapping)
        case options(MobileSourceEpisode, MobileSourceCatalog)
        case automatic(MobileSourceCandidate)
    }
    private enum AccessError: Error { case storageUnavailable }

    init(client: MobileSourceClient, requestedWork: PlaybackWorkIdentity? = nil,
         requestedEpisode: PlaybackEpisodeIdentity? = nil, enabled: Bool = false,
         library: MobileLibrary? = nil, authority: (() throws -> String)? = nil,
         searchAuthority: (() throws -> String)? = nil, resumeMapping: ConfirmedSourceMapping? = nil) {
        precondition((requestedWork == nil) == (requestedEpisode == nil))
        self.client = client
        self.requestedWork = requestedWork
        self.requestedEpisode = requestedEpisode
        self.enabled = enabled
        self.library = library
        self.authority = authority
        self.searchAuthority = searchAuthority
        searchRevision = MobileSourceEntry(source: client.source, imported: false, search: client.search).searchRevision
        configurationRevision = client.source.configurationRevision
        savedMapping = resumeMapping
        if let library, let requestedWork, let requestedEpisode, resumeMapping == nil {
            savedMapping = library.mapping(for: requestedWork, episode: requestedEpisode) ??
                library.storedMapping(for: requestedWork, episode: requestedEpisode)
            if let savedMapping {
                if !savedMapping.matches(work: requestedWork, episode: requestedEpisode) {
                    requiresReconfirmation = true
                    failure = .missingEpisode
                } else if let storedFailure = library.mappingFailure(for: requestedWork, episode: requestedEpisode) {
                    requiresReconfirmation = true
                    failure = storedFailure
                }
            } else if !library.isReadable { storageFailure = .unavailable }
        }
    }

    deinit { task?.cancel() }

    func updateAccess(enabled: Bool, configurationRevision: String) {
        self.enabled = enabled
        self.configurationRevision = configurationRevision
        do {
            if let savedMapping { try checkMapping(savedMapping) }
            try checkAccess()
            if failure == .sourceDisabled { failure = nil }
        } catch {
            cancel()
            reject(error)
        }
    }

    func search(_ keyword: String) {
        guard savedMapping == nil else { return }
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        results = []; nextPage = nil; catalog = nil; searched = false
        lastQuery = query
        run(.search(query, 1))
    }
    func openPage(_ address: String) {
        guard savedMapping == nil else { return }
        do {
            try checkAccess()
            open(try client.work(at: address))
        } catch {
            cancel(); lastAction = nil; reject(error)
        }
    }
    func loadMore() { if savedMapping == nil, !busy, let nextPage { run(.search(lastQuery, nextPage)) } }
    func open(_ work: MobileSourceWork) {
        guard savedMapping == nil else { return }
        catalog = nil; run(.catalog(work))
    }
    func acceptCandidate(_ candidate: MobileSourceCandidate, automatically: Bool) {
        guard savedMapping == nil, candidate.source.id == client.source.id,
              candidate.source.configurationRevision == client.source.configurationRevision else { return }
        if automatically, candidate.trusted, candidate.episode != nil {
            run(.automatic(candidate))
        } else {
            open(candidate.catalog.work)
        }
    }
    func play(_ episode: MobileSourceEpisode) {
        guard savedMapping == nil else { return }
        do { try checkAccess() }
        catch { cancel(); reject(error); return }
        guard let catalog else { cancel(); failure = .missingEpisode; return }
        run(.options(episode, catalog))
    }
    func choosePlaybackOption(_ episode: MobileSourceEpisode) {
        guard savedMapping == nil, playbackOptions.contains(episode), let optionsCatalog else { return }
        do { run(.resolve(episode, try client.selecting(episode, in: optionsCatalog))) }
        catch { cancel(); reject(error) }
    }
    func playSaved() {
        guard canPlaySaved, let savedMapping else { return }
        run(.reuse(savedMapping))
    }
    /// Deletion commits before unlocking manual selection or another source.
    func chooseSourceAgain() {
        let previousFailure = failure
        cancel()
        guard let library, let requestedWork, let requestedEpisode else { return }
        do {
            try library.removeMapping(for: requestedWork, episode: requestedEpisode)
            savedMapping = nil; requiresReconfirmation = false; storageFailure = nil
            catalog = nil; results = []; nextPage = nil; searched = false; lastAction = nil
        } catch { failure = previousFailure; storageFailure = .remove }
    }
    func retry() { if canRetry, let lastAction { run(lastAction) } }
    func back() { cancel(); catalog = nil; lastAction = nil }
    func cancel() {
        generation += 1; task?.cancel(); task = nil; busy = false; failure = nil
        resolved = nil
        playbackOptions = []; optionsCatalog = nil
    }

    /// Consume once, re-reading durable source/configuration authority at the actual session handoff.
    func takeResolved() -> MobileResolvedPlayback? {
        do {
            try checkAccess()
            guard let resolved else { return nil }
            if let savedMapping { try checkMapping(savedMapping) }
            guard !requiresReconfirmation,
                  resolved.context.configurationRevision == configurationRevision else { throw PlaybackFailure.configurationChanged }
            self.resolved = nil
            return resolved
        } catch {
            cancel(); reject(error)
            return nil
        }
    }

    private func checkAccess() throws {
        if let library, !library.isReadable { throw AccessError.storageUnavailable }
        if let authority {
            configurationRevision = try authority()
        } else {
            guard enabled else { throw PlaybackFailure.sourceDisabled }
        }
        guard configurationRevision == client.source.configurationRevision else { throw PlaybackFailure.configurationChanged }
    }

    private func checkSearchAccess() throws {
        guard let searchAuthority else { return }
        guard try searchAuthority() == searchRevision else { throw PlaybackFailure.configurationChanged }
    }

    private func checkMapping(_ mapping: ConfirmedSourceMapping) throws {
        guard mapping.context.selection.item.sourceID == client.source.id,
              mapping.context.configurationRevision == client.source.configurationRevision else {
            throw PlaybackFailure.configurationChanged
        }
        guard let requestedWork, let requestedEpisode, mapping.matches(work: requestedWork, episode: requestedEpisode) else {
            throw PlaybackFailure.missingEpisode
        }
        if let failure = library?.mappingFailure(for: requestedWork, episode: requestedEpisode) { throw failure }
        _ = try client.source.mappingSelection(mapping.context.selection)
    }

    private func reject(_ error: Error) {
        if error is AccessError { storageFailure = .unavailable; return }
        let classified = MobileSourceClient.failure(for: error)
        failure = classified
        guard savedMapping != nil, classified == .missingEpisode || classified == .configurationChanged else { return }
        requiresReconfirmation = true
        guard let library, let requestedWork, let requestedEpisode else { return }
        guard library.mappingFailure(for: requestedWork, episode: requestedEpisode) != classified else { return }
        do { try library.invalidateMapping(for: requestedWork, episode: requestedEpisode, failure: classified) }
        catch { storageFailure = .invalidate }
    }

    private func complete(_ episode: MobileSourceEpisode, catalog: MobileSourceCatalog,
                          url: URL, expected: Int, confirming: Bool) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        try checkAccess()
        let context = try client.playbackContext(episode, in: catalog,
            requestedWork: requestedWork, requestedEpisode: requestedEpisode)
        if confirming, let library {
            let mapping = ConfirmedSourceMapping(context: context, sourceTitle: catalog.work.title)
            do { try library.saveMapping(mapping) }
            catch { storageFailure = .save; return }
            savedMapping = mapping
        }
        resolved = MobileResolvedPlayback(url: url, title: catalog.work.title + " · " + episode.title, context: context)
    }

    private func run(_ action: Action) {
        cancel()
        storageFailure = nil
        lastAction = action
        do {
            try checkAccess()
            if case .search = action { try checkSearchAccess() }
        } catch { reject(error); return }
        let expected = generation
        busy = true
        let client = client
        task = Task { [weak self] in
            do {
                switch action {
                case .search(let query, let page):
                    let result = try await client.search(query, page: page)
                    try Task.checkCancellation()
                    guard let self, self.generation == expected else { return }
                    try self.checkAccess()
                    try self.checkSearchAccess()
                    var seen = Set(self.results.map(\.id))
                    self.results += result.works.filter { seen.insert($0.id).inserted }
                    self.nextPage = result.nextPage
                    self.searched = true
                    if self.results.isEmpty { self.failure = .noCandidates }
                case .catalog(let work):
                    let result = try await client.catalog(work)
                    try Task.checkCancellation()
                    guard let self, self.generation == expected else { return }
                    try self.checkAccess()
                    self.catalog = result
                case .options(let episode, let catalog):
                    try client.require(.mpv)
                    let options = try await client.playbackOptions(episode, in: catalog)
                    try Task.checkCancellation()
                    guard let self, self.generation == expected else { return }
                    try self.checkAccess()
                    if options.count == 1, let option = options.first {
                        let selected = try client.selecting(option, in: catalog)
                        let url = try await client.resolve(option, in: selected)
                        try self.complete(option, catalog: selected, url: url, expected: expected, confirming: true)
                    } else {
                        self.playbackOptions = options
                        self.optionsCatalog = catalog
                    }
                case .resolve(let episode, let catalog):
                    try client.require(.mpv)
                    _ = try client.playbackContext(episode, in: catalog, requestedWork: nil, requestedEpisode: nil)
                    let url = try await client.resolve(episode, in: catalog)
                    guard let self else { return }
                    try self.complete(episode, catalog: catalog, url: url, expected: expected, confirming: true)
                case .reuse(let mapping):
                    guard self != nil else { return }
                    try self?.checkMapping(mapping)
                    try client.require(.mpv)
                    let work = MobileSourceWork(item: mapping.context.selection.item, title: mapping.sourceTitle)
                    let catalog = try await client.catalog(work)
                    try Task.checkCancellation()
                    let selected = try await client.selectedEpisode(matching: mapping.context.selection, in: catalog)
                    guard let owner = self, owner.generation == expected else { return }
                    try owner.checkAccess()
                    let url = try await client.resolve(selected.episode, in: selected.catalog)
                    try owner.complete(selected.episode, catalog: selected.catalog, url: url, expected: expected, confirming: false)
                case .automatic(let candidate):
                    guard let self else { return }
                    guard candidate.trusted, let episode = candidate.episode,
                          let library = self.library, let work = self.requestedWork,
                          let requested = self.requestedEpisode, library.isReadable,
                          library.storedMapping(for: work, episode: requested) == nil else {
                        throw PlaybackFailure.configurationChanged
                    }
                    try self.checkAccess()
                    try client.require(.mpv)
                    let options = try await client.playbackOptions(episode, in: candidate.catalog)
                    try Task.checkCancellation()
                    guard self.generation == expected else { return }
                    try self.checkAccess()
                    guard options.count == 1, let option = options.first else {
                        self.catalog = candidate.catalog
                        self.playbackOptions = options
                        self.optionsCatalog = candidate.catalog
                        self.busy = false; self.task = nil
                        return
                    }
                    let selected = try client.selecting(option, in: candidate.catalog)
                    _ = try client.playbackContext(option, in: selected, requestedWork: work, requestedEpisode: requested)
                    let url = try await client.resolve(option, in: selected)
                    try Task.checkCancellation()
                    guard self.generation == expected else { return }
                    guard library.storedMapping(for: work, episode: requested) == nil else {
                        throw PlaybackFailure.configurationChanged
                    }
                    try self.complete(option, catalog: selected, url: url, expected: expected, confirming: true)
                }
                guard let self, self.generation == expected else { return }
                self.busy = false; self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.busy = false; self.reject(error); self.task = nil
            }
        }
    }
}

extension MobileSourceFlow.StorageFailure {
    var mobileMessage: String {
        switch self {
        case .unavailable:
            return String(localized: "Saved source selections could not be read. Reload the library before choosing or playing a source.")
        case .save:
            return String(localized: "The source selection could not be saved. Playback did not start. Select the source episode again to retry.")
        case .remove, .invalidate:
            return String(localized: "The saved source selection could not be changed. Existing data was preserved. Retry choosing the source again.")
        }
    }
}

extension PlaybackFailure {
    var mobileMessage: String {
        switch self {
        case .noCandidates: return String(localized: "No matching sources. Try another title or check again later.")
        case .missingEpisode: return String(localized: "The selected episode is missing. Confirm another source episode; no replacement was selected.")
        case .sourceDisabled: return String(localized: "This source is disabled. Enable it before sending a request.")
        case .configurationChanged: return String(localized: "The source configuration changed. Return to sources and confirm the episode again.")
        case .network: return String(localized: "The source request failed. Check your connection and retry.")
        case .httpForbidden: return String(localized: "The source refused the request (HTTP 403). This does not identify a video format or prove that sign-in will help.")
        case .websiteVerification: return String(localized: "The source returned a website verification or blocking page instead of source data.")
        case .sourceRedirect: return String(localized: "The source redirected to an address outside its configured hosts. Check the source domain configuration.")
        case .searchStructure: return String(localized: "The search response does not match the configured selectors or JSON fields. Update the search rules.")
        case .catalogStructure: return String(localized: "The episode page does not match the configured episode rules, or contains no usable episode links.")
        case .invalidPlayerData: return String(localized: "The player data is malformed, incomplete, or could not be decoded.")
        case .unsupportedEncryption: return String(localized: "The player declares an unsupported URL encryption method for this site or line.")
        case .indirectMedia: return String(localized: "The page provides a player identifier, embedded player, or URL without a supported media extension. Further resolution is required.")
        case .unsupportedMediaFormat: return String(localized: "The media URL extension is not supported by this source configuration.")
        case .unsafeMediaAddress: return String(localized: "The media address violates the source URL rules (HTTPS, host, credentials, port or fragment).")
        case .ambiguousMedia: return String(localized: "The page contains multiple different media addresses; the selected episode cannot be resolved unambiguously.")
        case .missingMedia: return String(localized: "No supported media address was found in the page. The site may require a separate API or dynamic player.")
        case .invalidResponseBody: return String(localized: "The source returned an empty response or exceeded the response size limit.")
        case .missingMediaQuality: return String(localized: "The page does not offer the resolution specified by this source configuration. No other resolution was selected.")
        case .appOnlyPlayback: return String(localized: "This line is restricted to the source's own app. Select the website line.")
        case .mediaSignatureMissing: return String(localized: "The source returned a legacy URL without an expiry signature (HTTP 401). Open the new XiFan site and reselect the work and episode; old IDs cannot be reused.")
        case .mediaNotFound: return String(localized: "The media file is unavailable on the source server (HTTP 404 or 410). Select another line.")
        case .playerServiceUnavailable: return String(localized: "The website player service could not resolve this stream. Retry later or select another line.")
        case .mediaPortUnsupported: return String(localized: "The media URL specifies a port that this source configuration does not support.")
        case .unsupportedResponse: return String(localized: "This source response or media format is unsupported. Confirm another source episode or choose a different source.")
        case .authenticationRequired: return String(localized: "This source requires sign-in or verification, which is not supported on iOS. Choose another source.")
        case .mediaPlayback: return String(localized: "The media could not be played. Choose another source episode or try again.")
        case .cancelled: return String(localized: "The source request was cancelled.")
        }
    }
}

enum MobileNextEpisodeError: Error {
    case qualityUnavailable
}

/// The player owns cancellation and load generations; this service rechecks durable authority around every await.
@MainActor
struct MobileSourceContinuation {
    let client: MobileSourceClient
    let authority: () throws -> String

    func validate(_ context: PlaybackContext) throws {
        try Task.checkCancellation()
        let revision = try authority()
        guard context.configurationRevision == revision,
              revision == client.source.configurationRevision,
              context.selection.item.sourceID == client.source.id else {
            throw PlaybackFailure.configurationChanged
        }
        try client.require(.mpv)
        if context.selection.item.kind == .work { try client.require(.episodes) }
        else { try client.require(.information) }
        let standalone = client.source.id == "hanime1" && context.selection.item.kind == .video &&
            context.selection.episode == context.selection.item && context.selection.lineID == "0" &&
            context.selection.qualityID.map(ConfirmedSourceMapping.safeLabel) == true
        guard context.selection.classification.kind != .live,
              context.selection.item.kind == .work || standalone, context.selection.torrent == nil else {
            throw PlaybackFailure.unsupportedResponse
        }
    }

    func resolve(after context: PlaybackContext, next: Bool, currentTitle: String) async throws -> MobileResolvedPlayback? {
        try validate(context)
        let work = MobileSourceWork(item: context.selection.item, title: "")
        let fresh = try await client.catalog(work)
        try validate(context)
        let current = try await client.selectedEpisode(matching: context.selection, in: fresh)
        try validate(context)
        let catalog: MobileSourceCatalog
        let episode: MobileSourceEpisode
        if next {
            guard let candidate = try client.nextEpisode(after: context.selection, in: current.catalog) else { return nil }
            let selection = PlayableSelection(item: context.selection.item, episode: candidate.item,
                lineID: String(candidate.line), qualityID: context.selection.qualityID,
                classification: context.selection.classification)
            let selected = try await client.selectedEpisode(matching: selection, in: current.catalog)
            episode = selected.episode; catalog = selected.catalog
        } else {
            episode = current.episode; catalog = current.catalog
        }
        let url = try await client.resolve(episode, in: catalog)
        try validate(context)
        let resolvedContext = try client.playbackContext(episode, in: catalog,
            requestedWork: context.work, requestedEpisode: next ? nil : context.episode)
        // Some native catalogues preserve the supplied title instead of extracting one.
        // Recover it only from the exact current episode suffix, preserving separators
        // inside the work name and never carrying the previous episode into the next title.
        let currentEpisode = current.episode
        let suffix = " · " + currentEpisode.title
        let previousWorkTitle = currentTitle.hasSuffix(suffix)
            ? String(currentTitle.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let catalogTitle = catalog.work.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let workTitle = catalogTitle.isEmpty ? previousWorkTitle : catalogTitle
        let title = workTitle.isEmpty ? episode.title : workTitle + " · " + episode.title
        return MobileResolvedPlayback(url: url, title: title, context: resolvedContext)
    }
}
