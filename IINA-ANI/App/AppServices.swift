import Cocoa

/// Only application/UI entry points resolve this root. Services receive their dependencies directly.
@MainActor
final class AppServices {
    static var current: AppServices {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            preconditionFailure("Application services require an application owner")
        }
        return delegate.services
    }

    let preferences: Preferences
    private let registry: SourceRegistry
    private let accounts: SiteAccounts
    lazy var sourceSubscription = SourceSubscriptionService(registry: registry)
    lazy var decoder: VideoDecoder = VideoDecoder(registry: registry, accounts: accounts,
        sourceEnabled: { [preferences] in preferences.isSourceEnabled($0) },
        localEndpoint: { [weak self] in
            guard let self else { throw VideoGetError.notSupported }
            return try await self.localEndpoint()
        })
    let iina: IINAApp
    let streaming: TorrentStreamingService
    lazy var httpServer: HttpServer = HttpServer(decoder: decoder, streaming: streaming,
        port: { [preferences] in preferences.dmPort }, enableDanmaku: { [preferences] in preferences.enableDanmaku })
    private let storage: () throws -> AppStoragePaths
    private let workLibrary: @MainActor () -> WorkLibrary?
    private var downloadService: DownloadService?
    private var historyStore: PlaybackHistoryStore?
    private var stopped = false
    private var jsPlayers: [UUID: (controller: JSPlayerWindowController, observer: NSObjectProtocol)] = [:]

    lazy var player: Processes = Processes(decoder: decoder, iina: iina, httpServer: httpServer,
        streaming: streaming, preferences: preferences, downloads: { [weak self] in
            guard let self else { throw DownloadFailure.invalidOperation }
            return try self.downloads()
        }, history: { [weak self] in
            guard let self else { throw DownloadFailure.invalidOperation }
            return try self.playbackHistory()
        }, completedSeason: { [weak self] selection, items, records, now in
            guard let self, let library = self.workLibrary() else { return nil }
            return try library.completedSeasonItems(for: selection, candidates: items, downloads: records, now: now)
        })

    init(preferences: Preferences = .shared, registry: SourceRegistry = .shared,
         accounts: SiteAccounts = .shared, storage: @escaping () throws -> AppStoragePaths = { try .production() },
         workLibrary: @escaping @MainActor () -> WorkLibrary? = { nil }) {
        self.preferences = preferences
        self.storage = storage
        self.registry = registry
        self.accounts = accounts
        self.workLibrary = workLibrary
        iina = IINAApp()
        streaming = TorrentStreamingService()

    }

    private func localEndpoint() async throws -> HTTPServerEndpoint {
        guard !stopped else { throw VideoGetError.notSupported }
        return try await httpServer.start()
    }

    func downloads() throws -> DownloadService {
        guard !stopped else { throw DownloadFailure.invalidOperation }
        if let downloadService { return downloadService }
        let service = try DownloadService.production(decoder: decoder, storage: storage(),
                                                    preferences: preferences, streaming: streaming)
        downloadService = service
        return service
    }

    func playbackHistory() throws -> PlaybackHistoryStore {
        if let historyStore { return historyStore }
        let owner = try PlaybackHistoryStore(url: storage().applicationSupport.appendingPathComponent("Playback/history-v1.json"), registry: registry)
        historyStore = owner
        return owner
    }

    func resumePlayback(_ entry: PlaybackHistoryEntry) async throws {
        guard !stopped else { throw Processes.ProcessesError.notSupported }
        let history = try playbackHistory()
        let savedSelection = try history.selectionForResume(entry)
        let startPosition = entry.awaitingUpdates == true ? 0 : entry.position
        if let torrent = entry.selection.torrent {
            let endpoint = try await localEndpoint()
            let policy = try TorrentUploadPolicy(bytesPerSecond: preferences.torrentUploadLimitBytesPerSecond,
                                                acknowledged: preferences.torrentUploadConsentAcknowledged)
            let grant = try await downloads().torrentPlayback(selection: torrent, uploadPolicy: policy, port: endpoint.port)
            _ = try history.selectionForResume(entry)
            _ = try await player.openTorrentPlayback(grant, startPosition: startPosition, title: entry.title, coverURL: entry.coverURL)
        } else {
            var selection = savedSelection
            var localURL: URL?
            if selection.item.kind == .local {
                do { localURL = try history.localFileForResume(entry) }
                catch PlaybackLocalFileAccessError.requiresAuthorization {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    guard panel.runModal() == .OK, let authorized = panel.url else { throw CancellationError() }
                    localURL = try history.localFileForResume(entry, authorizedURL: authorized)
                }
                selection.item = SourceItemRef(sourceID: "local", pageURL: localURL!.absoluteString, kind: .local)
            }
            let scoped = localURL?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { localURL?.stopAccessingSecurityScopedResource() } }
            if selection.item.kind != .local,
               registry.descriptor(for: selection.item.sourceID)?.capabilities.contains(.episodes) == true {
                guard let catalog = try await decoder.catalog(for: selection) else { throw PlaybackFailure.missingEpisode }
                _ = try history.selectionForResume(entry)
                try history.validateResumeCatalog(catalog, selection: selection)
            }
            var media = try await decoder.resolve(selection)
            _ = try history.selectionForResume(entry)
            try history.validateResolvedSelection(media.selection, requested: selection)
            guard let key = selection.qualityID ?? media.videos.first?.key else { throw VideoGetError.notFountData }
            media = try await decoder.prepareVideoUrl(media, key)
            _ = try history.selectionForResume(entry)
            try history.validateResolvedSelection(media.selection, requested: selection)
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            // Keep the actual bookmark URL for queue setup. History recognizes its
            // saved resource identity and retains the original persisted history ID.
            media.selection = selection
            if preferences.enableFlvjs && registry.descriptor(for: selection.item.sourceID)?.capabilities.contains(.jsPlayer) == true {
                try openJSPlayer(selection: savedSelection, title: entry.title, coverURL: entry.coverURL, startPosition: startPosition, episodeTitle: entry.episodeTitle)
            } else {
                try await player.prepareDanmakuFile(yougetJSON: media, id: media.uuid)
                _ = try history.selectionForResume(entry)
                try await player.openWithPlayer(media, key, title: entry.title, coverURL: entry.coverURL, startPosition: startPosition, episodeTitle: entry.episodeTitle)
            }
        }
    }

    /// The app, not a detail panel, owns each independent built-in player window.
    func openJSPlayer(selection: PlayableSelection, title: String? = nil, coverURL: String? = nil, startPosition: Double = 0, episodeTitle: String? = nil) throws {
        guard !stopped, registry.descriptor(for: selection.item.sourceID)?.capabilities.contains(.jsPlayer) == true,
              let controller = NSStoryboard(name: .player, bundle: nil).instantiateInitialController() as? JSPlayerWindowController,
              let content = controller.contentVC, let window = controller.window else {
            throw Processes.ProcessesError.notSupported
        }
        content.url = (selection.episode ?? selection.item).pageURL
        content.initialSelection = selection
        content.historyTitle = title
        content.historyCoverURL = coverURL
        content.historyEpisodeTitle = episodeTitle
        content.resumePosition = startPosition
        let id = UUID()
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let entry = self?.jsPlayers.removeValue(forKey: id) else { return }
                NotificationCenter.default.removeObserver(entry.observer)
            }
        }
        jsPlayers[id] = (controller, observer)
        window.makeKeyAndOrderFront(nil)
    }

    /// Search pagination and cancellation belong to the calling screen, never this root.
    func makeBrowseSearch() -> BrowseSearchService { BrowseSearchService(decoder: decoder) }

    func capabilityEnabled(_ capability: WorkspaceCapability) -> Bool {
        preferences.capabilityEnabled(capability)
    }

    func setCapability(_ capability: WorkspaceCapability, enabled: Bool) async throws {
        guard capability.canDisable else {
            throw WorkspaceCapabilityFailure(reasons: [capability.disableUnavailableReason ?? String(localized: "不能停用此能力。")])
        }
        if !enabled {
            let dependents = WorkspaceCapability.allCases.filter {
                $0.dependencies.contains(capability) && capabilityEnabled($0)
            }
            guard dependents.isEmpty else {
                throw WorkspaceCapabilityFailure(reasons: dependents.map { String(localized: "\($0.title) 仍依賴此能力。") })
            }
        }
        if capability == .downloads {
            try await downloads().setAcceptingNewTasks(enabled) { [preferences] in
                preferences.saveCapability(capability, enabled: enabled)
            }
        } else {
            preferences.saveCapability(capability, enabled: enabled)
        }
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true
        for entry in jsPlayers.values { await entry.controller.contentVC?.flushPlaybackHistory() }
        await player.stopTorrentPlayers()
        await httpServer.stop()
        await streaming.shutdown()
        if let downloadService { await downloadService.shutdown() }
    }
}
