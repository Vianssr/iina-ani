import Foundation
import Observation

struct PlaybackEpisode: Identifiable {
    let id = UUID()
    var url: URL
    let title: String
    /// nil identifies raw media links/local files without a source or catalogue association.
    let context: PlaybackContext?
    var localReference: MobileLocalMediaReference?

    init(url: URL, title: String? = nil, context: PlaybackContext? = nil,
         localReference: MobileLocalMediaReference? = nil) {
        self.url = url
        self.title = title ?? (url.isFileURL ? url.deletingPathExtension().lastPathComponent : String(localized: "Video"))
        self.context = context
        self.localReference = localReference
    }
}

@MainActor @Observable
final class PlaybackSession: Identifiable {
    let id = UUID()
    let engine = MPVEngine()
    let danmaku: MobileDanmakuStore
    private(set) var episodes: [PlaybackEpisode]
    private(set) var selectedIndex = 0
    private(set) var isPreparing = false
    var importFailed = false
    private var scopedURLs: [URL: MobileLocalMediaAccess] = [:]
    private var started = false
    private var stopped = false
    private var subtitleFiles: [UUID: [URL]] = [:]
    private var danmakuFiles: [UUID: URL] = [:]
    private var subtitlesOff = Set<UUID>()
    private let defaults: UserDefaults
    private let continuation: MobileSourceContinuation?
    var autoPlayNext: Bool {
        didSet {
            defaults.set(autoPlayNext, forKey: "mobile.player.autoPlayNext")
            if !autoPlayNext, advancingAutomatically { cancelNextEpisode() }
        }
    }
    private(set) var isAdvancing = false
    private(set) var nextError: String?
    private var foreground = true
    private var advanceTask: Task<Void, Never>?
    private var advanceRevision = 0
    private var advancingAutomatically = false
    private var handledEOF: PlaybackLoadIdentity?
    private let history: MobilePlaybackHistory?
    private let historyEntry: MobilePlaybackHistoryEntry?
    private let configuration: SourceConfiguration?
    private var recorder: MobilePlaybackHistoryRecorder?
    private var localAccess: [MobileLocalMediaAccess] = []
    private var preparation: Task<Void, Never>?
    private var loadRevision = 0
    private var hasSubmittedLoad = false
    private var activeEpisodeID: UUID?

    var current: PlaybackEpisode { episodes[selectedIndex] }
    var context: PlaybackContext? { current.context }

    var canRequestNext: Bool {
        guard !stopped, !isPreparing else { return false }
        if let context {
            return continuation != nil && context.selection.item.kind == .work &&
                context.selection.classification.kind != .live && context.selection.torrent == nil
        }
        return selectedIndex + 1 < episodes.count
    }

    private var resumePosition: Double? {
        guard !hasSubmittedLoad else { return nil }
        return historyEntry.flatMap { entry in
            let currentID = current.context.map(MobilePlaybackHistoryEntry.sourceID) ?? current.localReference?.identity.id
            return entry.id == currentID && !entry.completed ? entry.position : nil
        }
    }

    init(url: URL, securityScoped: Bool = false, title: String? = nil, context: PlaybackContext? = nil,
         history: MobilePlaybackHistory? = nil, historyEntry: MobilePlaybackHistoryEntry? = nil,
         configuration: SourceConfiguration? = nil, continuation: MobileSourceContinuation? = nil,
         defaults: UserDefaults = .standard) {
        self.defaults = defaults
        danmaku = MobileDanmakuStore(defaults: defaults)
        self.continuation = continuation
        autoPlayNext = defaults.bool(forKey: "mobile.player.autoPlayNext")
        self.history = history
        self.historyEntry = historyEntry
        self.configuration = configuration
        episodes = [PlaybackEpisode(url: url, title: title, context: context)]
        if securityScoped { retainAccess(url) }
        observePlayback()
    }

    init(urls: [URL], securityScoped: Bool = false, history: MobilePlaybackHistory? = nil,
         defaults: UserDefaults = .standard) {
        precondition(!urls.isEmpty)
        self.defaults = defaults
        danmaku = MobileDanmakuStore(defaults: defaults)
        continuation = nil
        autoPlayNext = defaults.bool(forKey: "mobile.player.autoPlayNext")
        self.history = history
        historyEntry = nil
        configuration = nil
        episodes = urls.map { PlaybackEpisode(url: $0) }
        if securityScoped { urls.forEach(retainAccess) }
        observePlayback()
    }

    static func resumeLocal(_ entry: MobilePlaybackHistoryEntry, history: MobilePlaybackHistory) async throws -> PlaybackSession {
        let revision = try history.authorizationRevision(for: entry)
        guard let reference = entry.localReference else { throw MobileLocalMediaError.unavailable }
        let authorized = try await MobileLocalMedia.resolve(reference)
        try Task.checkCancellation()
        let updated = try history.replaceLocalReference(authorized.reference, for: entry, expectedRevision: revision)
        return localSession(authorized, entry: updated, history: history)
    }

    static func reauthorizeLocal(_ entry: MobilePlaybackHistoryEntry, url: URL,
                                 history: MobilePlaybackHistory) async throws -> PlaybackSession {
        let revision = try history.authorizationRevision(for: entry)
        guard let reference = entry.localReference else { throw MobileLocalMediaError.unavailable }
        let authorized = try await MobileLocalMedia.authorize(url, matching: reference.identity)
        try Task.checkCancellation()
        let updated = try history.replaceLocalReference(authorized.reference, for: entry, expectedRevision: revision)
        return localSession(authorized, entry: updated, history: history)
    }

    private static func localSession(_ authorized: MobileAuthorizedLocalMedia, entry: MobilePlaybackHistoryEntry,
                                     history: MobilePlaybackHistory) -> PlaybackSession {
        let session = PlaybackSession(url: authorized.access.url, title: entry.title, history: history, historyEntry: entry)
        session.episodes[0].localReference = authorized.reference
        session.localAccess.append(authorized.access)
        return session
    }

    func start() {
        guard !started, !stopped else { return }
        started = true
        prepareAndLoad()
    }

    func selectEpisode(_ index: Int) {
        guard episodes.indices.contains(index), index != selectedIndex, !stopped else { return }
        cancelNextEpisode()
        nextError = nil
        if let target = episodes[index].context, continuation != nil {
            resolveEpisode(target, next: false, automatic: false)
        } else {
            switchEpisode(index)
        }
    }

    private func switchEpisode(_ index: Int) {
        recorder?.flush()
        recorder = nil
        if engine.selectedSubtitleID == nil { subtitlesOff.insert(current.id) }
        else { subtitlesOff.remove(current.id) }
        engine.setPaused(true)
        engine.clearSubtitles()
        danmaku.clear()
        selectedIndex = index
        prepareAndLoad()
    }

    func setForeground(_ active: Bool) {
        foreground = active
        if !active {
            cancelNextEpisode()
            engine.setPaused(true)
        }
    }

    func cancelNextEpisode() {
        advanceRevision += 1
        advanceTask?.cancel()
        advanceTask = nil
        isAdvancing = false
        advancingAutomatically = false
        nextError = nil
    }

    func nextEpisode() { advance(automatic: false) }

    private func advance(automatic: Bool) {
        guard !stopped, foreground, canRequestNext, !isAdvancing else { return }
        nextError = nil
        if let context {
            resolveEpisode(context, next: true, automatic: automatic)
        } else {
            // A pasted URL may be live. Only explicitly selected local files auto-advance.
            guard !automatic || (current.url.isFileURL && episodes[selectedIndex + 1].url.isFileURL) else { return }
            switchEpisode(selectedIndex + 1)
        }
    }

    private func resolveEpisode(_ context: PlaybackContext, next: Bool, automatic: Bool) {
        guard let continuation, foreground, !stopped else { return }
        cancelNextEpisode()
        let expected = advanceRevision
        let load = engine.playbackState.identity
        let episodeID = current.id
        isAdvancing = true
        advancingAutomatically = automatic
        advanceTask = Task { [weak self] in
            do {
                let result = try await continuation.resolve(after: context, next: next)
                try Task.checkCancellation()
                guard let self, !stopped, foreground, advanceRevision == expected,
                      current.id == episodeID, engine.playbackState.identity == load,
                      !automatic || autoPlayNext else { return }
                isAdvancing = false
                advancingAutomatically = false
                advanceTask = nil
                guard let result else {
                    nextError = String(localized: "No next episode is available in this source group.")
                    return
                }
                #if DEBUG
                let url = SourceFixtures.playerURL(result.url)
                #else
                let url = result.url
                #endif
                let index: Int
                if let existing = episodes.firstIndex(where: { $0.context?.selection == result.context.selection }) {
                    episodes[existing].url = url
                    index = existing
                } else {
                    episodes.append(PlaybackEpisode(url: url, title: result.title, context: result.context))
                    index = episodes.count - 1
                }
                switchEpisode(index)
            } catch {
                guard let self, !Task.isCancelled, advanceRevision == expected else { return }
                isAdvancing = false
                advancingAutomatically = false
                advanceTask = nil
                if error is MobileNextEpisodeError {
                    nextError = String(localized: "The original quality is unavailable for the next episode.")
                } else {
                    nextError = MobileSourceClient.failure(for: error).mobileMessage
                }
            }
        }
    }

    private func prepareAndLoad() {
        preparation?.cancel()
        loadRevision += 1
        let expected = loadRevision
        let index = selectedIndex
        isPreparing = true
        preparation = Task { [weak self] in
            guard let self else { return }
            defer { if loadRevision == expected { isPreparing = false } }
            do {
                if let historyEntry, loadRevision == 1 {
                    guard history?.entries.contains(historyEntry) == true else { throw MobileLocalMediaError.staleHistory }
                    if let context = current.context {
                        guard historyEntry.context?.work == context.work, historyEntry.context?.episode == context.episode,
                              historyEntry.id == MobilePlaybackHistoryEntry.sourceID(context) else {
                            throw MobileLocalMediaError.staleHistory
                        }
                    }
                }
                if current.context == nil, current.url.isFileURL, current.localReference == nil, history != nil {
                    let authorized = try await MobileLocalMedia.authorize(current.url, retaining: scopedURLs[current.url])
                    try Task.checkCancellation()
                    guard !stopped, loadRevision == expected, selectedIndex == index else { return }
                    episodes[index].localReference = authorized.reference
                    localAccess.append(authorized.access)
                }
                try Task.checkCancellation()
                guard !stopped, loadRevision == expected, selectedIndex == index else { return }
                if let context { try continuation?.validate(context) }
                activeEpisodeID = current.id
                engine.load(url: current.url, context: current.context, resumePosition: resumePosition, paused: !foreground)
                hasSubmittedLoad = true
                beginAutomaticDanmaku()
                for url in subtitleFiles[current.id] ?? [] { engine.addSubtitle(url: url) }
                if subtitlesOff.contains(current.id) { engine.selectSubtitle(id: nil) }
                if let url = danmakuFiles[current.id] {
                    do { try danmaku.load(url: url) }
                    catch { importFailed = true }
                }
                loadTestDanmakuIfNeeded()
            } catch is CancellationError {
                return
            } catch {
                guard !stopped, loadRevision == expected else { return }
                engine.errorMessage = String(localized: "Unable to open this media.")
            }
        }
    }

    private func beginAutomaticDanmaku() {
        let episodeID = current.id
        let context = current.context
        let target: MobileDanmakuTarget?
        if let configuration, let context, continuation != nil,
           let binding = try? configuration.danmakuBinding(for: context.selection, revision: context.configurationRevision) {
            target = MobileDanmakuTarget(episodeID: episodeID, sourceID: configuration.id,
                pageURL: binding.pageURL, configurationRevision: configuration.configurationRevision,
                aid: binding.aid, cid: binding.cid)
        } else {
            target = nil
        }
        danmaku.beginEpisode(target: target) { [weak self] in
            guard let self, !stopped, current.id == episodeID, let context, let continuation else {
                throw CancellationError()
            }
            try continuation.validate(context)
        }
    }

    private func observePlayback() {
        engine.onSubtitleImported = { [weak self] url in
            guard let self, !stopped, activeEpisodeID == current.id else { return }
            if subtitleFiles[current.id]?.contains(url) != true { subtitleFiles[current.id, default: []].append(url) }
            subtitlesOff.remove(current.id)
        }
        engine.onPauseRequested = { [weak self] in
            self?.recorder?.flush()
            if self?.advancingAutomatically == true { self?.cancelNextEpisode() }
        }
        engine.onResumeConfirmed = { [weak self] identity in self?.recorder?.confirmResume(identity) }
        engine.onPlaybackEvent = { [weak self] event in
            guard let self, !stopped, activeEpisodeID == current.id else { return }
            if case .resolved = event.kind {
                cancelNextEpisode()
                recorder?.flush()
                recorder = history?.begin(context: current.context, localReference: current.localReference,
                    title: current.title, configuration: configuration, identity: event.identity, resumePosition: resumePosition)
            }
            recorder?.receive(event)
            switch event.kind {
            case .failed, .cancelled, .stopped: cancelNextEpisode()
            default: break
            }
            if case .naturalEOF = event.kind, handledEOF != event.identity {
                handledEOF = event.identity
                if autoPlayNext && foreground { advance(automatic: true) }
            }
        }
    }

    func append(urls: [URL], securityScoped: Bool = false) {
        guard !stopped else { return }
        for url in urls where !episodes.contains(where: { $0.url == url }) {
            if securityScoped { retainAccess(url) }
            episodes.append(PlaybackEpisode(url: url))
        }
    }

    func importSubtitle(_ url: URL) {
        guard !stopped else { return }
        // libmpv may read the subtitle lazily, so keep its authorization for this session.
        retainAccess(url)
        engine.addSubtitle(url: url)
    }

    func importDanmaku(_ url: URL) {
        guard !stopped else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try danmaku.load(url: url)
            retainAccess(url)
            danmakuFiles[current.id] = url
        } catch { importFailed = true }
    }

    func stop() {
        guard !stopped else { return }
        cancelNextEpisode()
        recorder?.flush()
        recorder = nil
        stopped = true
        preparation?.cancel()
        preparation = nil
        loadRevision += 1
        isPreparing = false
        let releasing = scopedURLs
        let releasingLocal = localAccess
        engine.stop(onStopped: {
            withExtendedLifetime(releasing) {}
            withExtendedLifetime(releasingLocal) {}
        })
        localAccess.removeAll()
        scopedURLs.removeAll()
        subtitleFiles.removeAll()
        danmakuFiles.removeAll()
        subtitlesOff.removeAll()
        danmaku.clear()
    }

    private func retainAccess(_ url: URL) {
        guard scopedURLs[url] == nil else { return }
        scopedURLs[url] = MobileLocalMediaAccess(url: url)
    }

    private func loadTestDanmakuIfNeeded() {
        #if DEBUG
        if selectedIndex == 0, danmakuFiles[current.id] == nil,
           ProcessInfo.processInfo.arguments.contains("-player-ui-fixture"),
           let url = Bundle.main.url(forResource: "player-fixture", withExtension: "xml") {
            importDanmaku(url)
        }
        #endif
    }
}
