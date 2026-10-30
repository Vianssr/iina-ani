//
//  YouGet.swift
//  iina+
//
//  Created by xjbeta on 2018/7/5.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Foundation
import Marshal
import Cocoa
 
@MainActor
final class Processes: NSObject, Sendable {
    
	enum ProcessesError: Error {
		case openFailed(String)
		case urlNotFound
		case notSupported
	}
	
    private let decoder: VideoDecoder
    let iina: IINAApp
    private let httpServer: HttpServer
    private let streaming: TorrentStreamingService
    private let preferences: Preferences
    private let downloads: @MainActor () throws -> DownloadService
    private let history: @MainActor () throws -> PlaybackHistoryStore
    private let completedSeason: @MainActor (PlayableSelection, [SourceItemRef], [DownloadRecord], Date) throws -> [SourceItemRef]?
    private var progressPlayers: [UUID: PlayerProgressSession] = [:]
    private var autoplayTasks: [UUID: Task<Void, Never>] = [:]
    private var continuationRevisions: [UUID: UUID] = [:]

    var nextEpisodePlayers: [(id: UUID, title: String)] {
        progressPlayers.values.filter {
            $0.canAdvance && $0.selection.torrent == nil && $0.selection.item.kind != .live &&
                $0.selection.classification.kind != .live
        }.map { ($0.id, $0.displayTitle) }.sorted {
            $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 < $1.1
        }
    }

    func cancelNextEpisode(_ id: UUID, includingQueue: Bool = true) {
        continuationRevisions.removeValue(forKey: id)
        autoplayTasks.removeValue(forKey: id)?.cancel()
        if includingQueue { progressPlayers[id]?.cancelPendingNextEpisode() }
    }

    func requestNextEpisode(_ id: UUID) {
        guard let session = progressPlayers[id], session.canAdvance else { return }
        beginContinuation(session, title: session.displayTitle, coverURL: nil,
                          recorder: session.continuationRecorder, automatic: false)
    }
    private var stopped = false

    func openDownloadedFile(_ id: UUID) async throws {
        let file = try await downloads().fileForOpening(id)
        var media = YouGetJSON(url: file.absoluteString)
        media.site = .local
        media.rawUrl = file.absoluteString
        media.title = file.lastPathComponent
        media.selection = PlayableSelection(item: SourceItemRef(sourceID: "local", pageURL: file.absoluteString, kind: .local))
        try await prepareDanmakuFile(yougetJSON: media, id: media.uuid)
        let record = try await downloads().record(id)
        try await openWithPlayer(media, "url", title: record.title, coverURL: record.coverURL, episodeTitle: record.episodeTitle)
    }

    private var torrentPlayers: [UUID: TorrentPlayerSession] = [:]

    @discardableResult
    func openTorrent(_ id: UUID) async throws -> TorrentPlayerSession {
        let endpoint = try await httpServer.start()
        let grant = try await downloads().torrentPlayback(id, port: endpoint.port)
        return try await openTorrentPlayback(grant)
    }

    @discardableResult
    func openTorrent(importID: UUID, fileIndex: Int, uploadPolicy: TorrentUploadPolicy) async throws -> TorrentPlayerSession {
        let endpoint = try await httpServer.start()
        let grant = try await downloads().torrentPlayback(importID: importID, fileIndex: fileIndex,
            uploadPolicy: uploadPolicy, port: endpoint.port)
        return try await openTorrentPlayback(grant)
    }

    /// Torrent playback needs per-window IPC; URL-scheme success cannot own its lifetime.
    func openTorrentPlayback(_ grant: TorrentPlaybackGrant, startPosition: Double = 0, title: String? = nil, coverURL: String? = nil) async throws -> TorrentPlayerSession {
        do {
            try Task.checkCancellation()
            let choice = PlayableSelection(item: SourceItemRef(sourceID: "torrent", pageURL: grant.selection.identityURL.absoluteString, kind: .video), torrent: grant.selection)
            let recorder = PlaybackProgressRecorder(store: try history(), selection: choice, title: title ?? grant.selection.path, coverURL: coverURL)
            let session = try TorrentPlayerSession(grant: grant, streaming: streaming, recorder: recorder) { [weak self] id in self?.torrentPlayers.removeValue(forKey: id) }
            let isIINA = preferences.livePlayer == .iina
            let executable = isIINA ? "/Applications/IINA.app/Contents/MacOS/iina-cli" : (which("mpv").first ?? "")
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                await session.stop(sendStop: false)
                throw ProcessesError.notSupported
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            let options = ["input-ipc-server=\(session.socketURL.path)", "force-seekable=yes", "start=\(startPosition)", "resume-playback=no"]
            process.arguments = (isIINA ? ["--no-stdin", "--separate-windows"] : []) +
                options.map { (isIINA ? "--mpv-" : "--") + $0 } + [grant.url.absoluteString]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() }
            catch { await session.stop(sendStop: false); throw ProcessesError.openFailed(String(localized: "Player launch failed")) }
            torrentPlayers[grant.id] = session
            session.observe()
            return session
        } catch {
            await streaming.revoke(grant.id)
            throw error
        }
    }

    func stopTorrentPlayback(_ id: UUID) async { await torrentPlayers[id]?.stop() }

    func stopTorrentPlayers() async {
        stopped = true
        let pending = Array(autoplayTasks.values)
        autoplayTasks.removeAll()
        for task in pending { task.cancel() }
        for session in Array(torrentPlayers.values) { await session.stop() }
        for session in Array(progressPlayers.values) { await session.stop() }
        for task in pending { await task.value }
    }


    
    
    init(decoder: VideoDecoder, iina: IINAApp, httpServer: HttpServer,
         streaming: TorrentStreamingService, preferences: Preferences,
         downloads: @escaping @MainActor () throws -> DownloadService,
         history: @escaping @MainActor () throws -> PlaybackHistoryStore,
         completedSeason: @escaping @MainActor (PlayableSelection, [SourceItemRef], [DownloadRecord], Date) throws -> [SourceItemRef]?) {
        self.decoder = decoder
        self.iina = iina
        self.httpServer = httpServer
        self.streaming = streaming
        self.preferences = preferences
        self.downloads = downloads
        self.history = history
        self.completedSeason = completedSeason
    }
    
    func which(_ str: String) -> [String] {
        // which you-get
        // command -v you-get
        // type -P you-get
		
		guard preferences.customMpvPath == "" else {
			return [preferences.customMpvPath]
		}
		
		let (process, outText, errText) = Process.run([
			"/bin/bash", "-l", "-c", "which mpv"
		])
		
		guard process.terminationStatus == 0, let out = outText else {
			Log("outText: \(outText ?? "none")")
			Log("errText: \(errText ?? "none")")
			return []
		}
		
		return out.components(separatedBy: "\n").filter({ $0 != "" })
    }

    func mpvVersion() -> String {
		
		var cmd = "mpv -V"
		
		if preferences.customMpvPath != "" {
			cmd = preferences.customMpvPath + " -V"
		}
		
		let (process, outText, errText) = Process.run([
			"/bin/bash", "-l", "-c", cmd
		])
		
		guard process.terminationStatus == 0, let out = outText else {
			Log("outText: \(outText ?? "none")")
			Log("errText: \(errText ?? "none")")
			return "unknown"
		}
		
		let str = out.components(separatedBy: "\n").filter {
			$0 != ""
			&& $0.starts(with: "mpv")
			&& $0.contains("Copyright")
		}.first ?? ""
		
		return str.subString(from: "mpv", to: "Copyright").replacingOccurrences(of: " ", with: "")
    }
    
    func prepareDanmakuFile(yougetJSON: YouGetJSON, id: String) async throws {
        guard preferences.enableDanmaku, preferences.livePlayer == .iina else { return }
        if yougetJSON.site == .local, yougetJSON.id == -1,
           let selection = yougetJSON.selection,
           let xml = AutoplaySelection.localDanmakuURL(for: selection),
           VideoDecoder.dmPath(id).map({ !FileManager.default.fileExists(atPath: $0) }) == true {
            VideoDecoder.saveDMFile(try Data(contentsOf: xml), with: id)
            return
        }
        guard await iina.archiveType != .normal,
              [.bilibili, .bangumi, .local].contains(yougetJSON.site), yougetJSON.id != -1 else { return }
        try await decoder.downloadDMFileV2(cid: yougetJSON.id, length: yougetJSON.duration,
                                          id: id, selection: yougetJSON.selection)
    }

    /// Called only for natural EOF. Season cleanup is independent of autoplay.
    func completeEpisode(after selection: PlayableSelection, completedAt: Date = Date(),
                         recorder: PlaybackProgressRecorder? = nil) async throws -> PlayableSelection? {
        try Task.checkCancellation()
        try recorder?.validateForContinuation()
        guard !stopped, selection.torrent == nil,
              selection.item.sourceID != "torrent", selection.item.kind != .live,
              selection.episode?.kind != .live, selection.classification.kind != .live,
              decoder.registry.classification(for: selection.item).kind != .live else { return nil }
        do {
            if selection.item.sourceID == "local" {
                let next = try AutoplaySelection.localNext(after: selection)
                if next == nil {
                    try await finishSeason(selection, items: AutoplaySelection.localCompletedItems(after: selection),
                                           completedAt: completedAt, recorder: recorder)
                } else if !preferences.autoPlayNext {
                    try recorder?.retainForUpdates(through: completedAt)
                }
                return preferences.autoPlayNext ? next : nil
            }
            let current = selection.episode ?? selection.item
            guard current.sourceID == selection.item.sourceID else { return nil }
            // A work URL may default to its first episode; request the actual played page instead.
            var catalogChoice = selection
            catalogChoice.item = current
            catalogChoice.episode = nil
            guard let catalog = try await decoder.catalog(for: catalogChoice) else {
                try recorder?.retainForUpdates(through: completedAt)
                return nil
            }
            try Task.checkCancellation()
            guard !stopped else { throw CancellationError() }
            try recorder?.validateForContinuation()
            try history().validateResumeCatalog(catalog, selection: selection)
            let next = AutoplaySelection.next(after: selection, in: catalog.nodes, registry: decoder.registry)
            if next == nil {
                try await finishSeason(selection,
                    items: AutoplaySelection.completedItems(after: selection, in: catalog.nodes, registry: decoder.registry),
                    completedAt: completedAt, recorder: recorder)
            } else if !preferences.autoPlayNext {
                try recorder?.retainForUpdates(through: completedAt)
            }
            return preferences.autoPlayNext ? next : nil
        } catch {
            try recorder?.retainForUpdates(through: completedAt)
            throw error
        }
    }

    private func finishSeason(_ selection: PlayableSelection, items: [SourceItemRef]?,
                              completedAt: Date, recorder: PlaybackProgressRecorder?) async throws {
        let records: [DownloadRecord]
        if selection.item.sourceID == "local" { records = try await downloads().completedDownloads() }
        else { records = [] }
        if let items, let confirmed = try completedSeason(selection, items, records, completedAt) {
            try Task.checkCancellation()
            try recorder?.validateForContinuation()
            guard !stopped else { throw CancellationError() }
            try history().removeCompletedSeason(confirmed, through: completedAt, registry: decoder.registry)
        } else {
            try recorder?.retainForUpdates(through: completedAt)
        }
    }

    private func beginContinuation(_ session: PlayerProgressSession, title: String?, coverURL: String?,
                                   recorder: PlaybackProgressRecorder, automatic: Bool) {
        guard !stopped else { return }
        let id = session.id
        cancelNextEpisode(id)
        let revision = UUID()
        continuationRevisions[id] = revision
        let completedAt = Date()
        let selection = recorder.selection
        autoplayTasks[id] = Task { [weak self, weak session] in
            guard let self, let session else { return }
            defer {
                if continuationRevisions[id] == revision {
                    continuationRevisions.removeValue(forKey: id)
                    autoplayTasks.removeValue(forKey: id)
                }
            }
            do {
                if !automatic {
                    if selection.item.sourceID == "local" {
                        try await session.nextLocalEpisode()
                        return
                    }
                    try await session.pauseForTransition()
                }
                try recorder.validateForContinuation()
                let next: PlayableSelection?
                if automatic {
                    next = try await completeEpisode(after: selection, completedAt: completedAt, recorder: recorder)
                } else {
                    var catalogChoice = selection
                    catalogChoice.item = selection.episode ?? selection.item
                    catalogChoice.episode = nil
                    guard let catalog = try await decoder.catalog(for: catalogChoice) else {
                        throw PlaybackFailure.missingEpisode
                    }
                    try recorder.validateForContinuation()
                    try history().validateResumeCatalog(catalog, selection: selection)
                    next = AutoplaySelection.next(after: selection, in: catalog.nodes, registry: decoder.registry)
                    guard next != nil else {
                        throw NSError(domain: "IINA-ANI.NextEpisode", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: String(localized: "No next episode is available in this source group.")])
                    }
                }
                guard let next else { return }
                try Task.checkCancellation()
                try recorder.validateForContinuation()
                var media = try await decoder.resolve(next)
                try history().validateResolvedSelection(media.selection, requested: next)
                guard let key = next.qualityID ?? media.videos.first?.key,
                      media.streams[key] != nil else { throw VideoGetError.notFountData }
                media = try await decoder.prepareVideoUrl(media, key)
                try history().validateResolvedSelection(media.selection, requested: next)
                try await prepareDanmakuFile(yougetJSON: media, id: media.uuid)
                try Task.checkCancellation()
                try recorder.validateForContinuation()
                guard !stopped, continuationRevisions[id] == revision, session.canAdvance,
                      !automatic || preferences.autoPlayNext else { return }
                try await openWithPlayer(media, key, title: title, coverURL: coverURL,
                                         episodeTitle: media.title, autoplay: automatic)
                await session.stopPlayback()
            } catch is CancellationError {
                return
            } catch {
                if automatic {
                    do { try recorder.retainForUpdates(through: completedAt) }
                    catch { NSLog("Completed playback history could not be retained.") }
                }
                guard !stopped, !Task.isCancelled, continuationRevisions[id] == revision else { return }
                let visible = NSError(domain: "IINA-ANI.Autoplay", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "Unable to play next episode"),
                    NSLocalizedRecoverySuggestionErrorKey: String(localized: "來源目錄確認、觀看記錄保存或下一集啟播失敗；已停止後續操作，未切換來源、線路或品質。"),
                    NSUnderlyingErrorKey: error
                ])
                NSApplication.shared.presentError(visible)
            }
        }
    }
    
    func openWithPlayer(_ json: YouGetJSON, _ key: String, title: String? = nil, coverURL: String? = nil, startPosition: Double = 0, episodeTitle: String? = nil, autoplay: Bool = false) async throws {
        try Task.checkCancellation()
        var selectedJSON = json
        guard !stopped, !autoplay || preferences.autoPlayNext else { throw CancellationError() }
        if selectedJSON.selection == nil {
            // Legacy/local XML entry points still get an exact durable identity and isolated IPC.
            let page = selectedJSON.rawUrl.isEmpty ? selectedJSON.streams[key]?.url : selectedJSON.rawUrl
            if let page, let item = try? decoder.registry.item(for: page) {
                selectedJSON.selection = PlayableSelection(item: item, classification: decoder.registry.classification(for: item))
                if item.kind == .local { selectedJSON.site = .local; selectedJSON.rawUrl = item.pageURL }
            }
        }
        if var selection = selectedJSON.selection {
            selection.qualityID = key
            selectedJSON.selection = selection
        }
        // Capture configuration authority before asynchronous player preparation.
        let initialRecorder: PlaybackProgressRecorder?
        if let choice = selectedJSON.selection, choice.classification.kind != .live, choice.item.kind != .live {
            initialRecorder = PlaybackProgressRecorder(store: try history(), selection: choice,
                title: title ?? selectedJSON.title, coverURL: coverURL, episodeTitle: episodeTitle)
        } else {
            initialRecorder = nil
        }
		await iina.updateIINAState()
		let type = await iina.archiveType
		let buildVersion = await iina.buildVersion
        
        let endpoint: HTTPServerEndpoint?
        if preferences.livePlayer == .iina {
            endpoint = try await httpServer.start()
        } else {
            endpoint = nil
        }
        var context = try PlaybackPreparation.context(for: selectedJSON, key: key, endpoint: endpoint, enableDanmaku: preferences.enableDanmaku && decoder.registry.descriptor(for: selectedJSON.site.sourceID)?.capabilities.contains(.danmaku) == true)
        context.playerOptions = ["start=\(startPosition)", "resume-playback=no"]
        let localQueue = try selectedJSON.selection.map { try AutoplaySelection.localQueue(for: $0) } ?? []
        if initialRecorder != nil {
            // Keep the IPC owner alive at EOF: close, replay or manual replacement cancels pending next lookups.
            context.playerOptions += ["keep-open=always", "loop-file=no", "loop-playlist=no"]
        }
        var encoder = PlaybackEncoder(media: selectedJSON, context: context)
        var progress: PlayerProgressSession?
        if let choice = selectedJSON.selection, let recorder = initialRecorder {
            let store = try history()
            let records = localQueue.isEmpty ? [] : try await downloads().completedDownloads()
            let enableDanmaku = preferences.enableDanmaku
            var paths = Set([encoder.videoUrl(key), encoder.videoUrl(key, forDash: true), selectedJSON.streams[key]?.url].compactMap { $0 })
            for path in Array(paths) { if let url = URL(string: path), url.isFileURL { paths.insert(url.path) } }
            if let endpoint { paths.insert("http://127.0.0.1:\(endpoint.port)/video.mp4?session=\(selectedJSON.uuid)") }
            let historyTitle = title ?? selectedJSON.title
            weak var owner: PlayerProgressSession?
            let session = try PlayerProgressSession(recorder: recorder, paths: paths, localQueue: localQueue,
                nativePlaylist: preferences.livePlayer == .iina,
                initialStartPosition: startPosition,
                retainsEOF: localQueue.isEmpty,
                autoplayEnabled: { [preferences] in preferences.autoPlayNext },
                makeRecorder: { selection in
                    if selection.item == choice.item {
                        return PlaybackProgressRecorder(store: store, selection: selection,
                            title: historyTitle, coverURL: coverURL, episodeTitle: episodeTitle)
                    }
                    let file = URL(string: selection.item.pageURL)
                    let record = records.first { $0.completedFile?.standardizedFileURL == file?.standardizedFileURL }
                    return PlaybackProgressRecorder(store: store, selection: selection,
                        title: record?.title ?? file?.lastPathComponent ?? "",
                        coverURL: record?.coverURL, episodeTitle: record?.episodeTitle)
                }, onQueueEOF: { [weak self] recorder in
                    guard let self else { return nil }
                    do { return try await self.completeEpisode(after: recorder.selection, recorder: recorder) }
                    catch {
                        NSApplication.shared.presentError(error)
                        throw error
                    }
                }, queueItemOptions: { [context] selection in
                    let file = URL(string: selection.item.pageURL)
                    var options = ["start": "0", "force-media-title": file?.lastPathComponent ?? "", "referrer": ""]
                    let xml = selection.item == choice.item ? context.danmakuFile :
                        (enableDanmaku ? AutoplaySelection.localDanmakuURL(for: selection)?.path : nil)
                    if let endpoint, let xml {
                        var media = YouGetJSON(url: selection.item.pageURL)
                        // Queued files are already real media: load XML without asking
                        // the plugin to redirect/reload and replace the native playlist.
                        media.streams = [:]
                        media.site = .local
                        media.rawUrl = selection.item.pageURL
                        media.selection = selection
                        media.title = file?.lastPathComponent ?? ""
                        let itemContext = PlaybackEncodingContext(endpoint: endpoint,
                            enableDanmaku: false, danmakuFile: xml)
                        options["referrer"] = PlaybackEncoder(media: media, context: itemContext).iinaPlusArgsString("url")
                    }
                    return options
                }, onEOF: { [weak self] recorder in
                    guard let self, let owner else { return }
                    self.beginContinuation(owner, title: historyTitle, coverURL: coverURL, recorder: recorder, automatic: true)
                }, onFinish: { [weak self] id in
                    self?.cancelNextEpisode(id)
                    self?.progressPlayers.removeValue(forKey: id)
                })
            owner = session
            session.onPlaybackEvent = { [weak self] event in
                switch event.kind {
                case .resolved, .cancelled:
                    self?.cancelNextEpisode(event.identity.sessionID, includingQueue: false)
                case .stopped, .failed:
                    self?.cancelNextEpisode(event.identity.sessionID)
                default: break
                }
            }
            progress = session
            context.playerOptions.append("input-ipc-server=\(session.socketURL.path)")
            encoder = PlaybackEncoder(media: selectedJSON, context: context)
        }
        let urlScheme = encoder.iinaURLScheme(key, type: type)
		
        do {
        try Task.checkCancellation()
        guard !stopped, !autoplay || preferences.autoPlayNext else { throw CancellationError() }
        try initialRecorder?.validateForLaunch()
        switch preferences.livePlayer {
        case .iina where !localQueue.isEmpty:
            // A real playlist disables IINA's asynchronous folder auto-add, which
            // would otherwise duplicate the queue. CLI options establish isolated IPC.
            guard let playlist = progress?.playlistURL,
                  let index = localQueue.firstIndex(where: { $0.item == selectedJSON.selection?.item }) else {
                throw ProcessesError.openFailed(String(localized: "Missing local playlist"))
            }
            try await openWithProcess(playlist.path, args: encoder.mpvOptions + ["playlist-start=\(index)"],
                                      uuid: selectedJSON.uuid, autoplay: autoplay)
        case .iina where type == .plugin:
			// IINA Danmaku Plguin
            try openWithURLScheme(urlScheme)
        case .iina where type == .normal && buildVersion >= 90:
			// IINA Official with URL Scheme + MPV Options
            // 1.0.0 beta3 build 86  URL Scheme without mpv options
            // 1.0.0 beta4 build 90
			try openWithURLScheme(urlScheme)
		case .iina where type == .danmaku && buildVersion >= 15:
			// IINA-Danmaku 1.1.2 NEW API
			try openWithURLScheme(urlScheme)
		case .iina where type == .danmaku && buildVersion < 15:
			// IINA-Danmaku cli
            try await openWithProcess(encoder.videoUrl(key), args: encoder.mpvOptions, uuid: selectedJSON.uuid, autoplay: autoplay)
        case .iina where type == .normal && buildVersion >= 56:
			// IINA Official with cli
			// iinc-cli build 56
            try await openWithProcess(encoder.videoUrl(key, forDash: true), args: encoder.mpvOptions, uuid: selectedJSON.uuid, autoplay: autoplay)
        case .mpv:
            try await openWithProcess(encoder.videoUrl(key), args: encoder.mpvOptions, uuid: selectedJSON.uuid, autoplay: autoplay)
        default:
			throw ProcessesError.notSupported
        }
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        } catch {
            await progress?.stop()
            throw error
        }
        if let progress { progressPlayers[progress.id] = progress; progress.observe() }
    }
    
    private func openWithProcess(_ url: String?, args: [String], uuid: String, autoplay: Bool) async throws {
        try Task.checkCancellation()
		guard let url, url != "" else {
			throw ProcessesError.openFailed("Nil url")
		}
		
        let livePlayer = preferences.livePlayer
        let isIINA = livePlayer == .iina
        var args = args
		
        if isIINA {
			let type = await iina.archiveType
            args = args.map {
                "--mpv-" + $0
            }
            args.append(contentsOf: ["--no-stdin", "--separate-windows"])
            if type == .danmaku {
                if preferences.enableDanmaku {
                    args.append("--danmaku")
                    args.append("--uuid=\(uuid)")
                }
                args.append("--directly")
            }
        } else {
            args.append(MPVOption.Terminal.reallyQuiet)
			args.append(MPVOption.Terminal.noTerminal)
            args = args.map {
                "--" + $0
            }
        }
        args.insert(url, at: 0)
		
		let launchPath = isIINA ? livePlayer.rawValue : "\(self.which(livePlayer.rawValue).first ?? "")"
		
		guard launchPath != "" else {
			throw ProcessesError.openFailed(String(localized: "Not found launchPath"))
		}
		
        try Task.checkCancellation()
        guard !stopped, !autoplay || preferences.autoPlayNext else { throw CancellationError() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw ProcessesError.openFailed(String(localized: "Player launch failed")) }
		
    }
    
    private func openWithURLScheme(_ url: String?) throws {
        try Task.checkCancellation()
        guard let url, url != "", let u = URL(string: url) else {
            throw ProcessesError.openFailed(String(localized: "Invalid player URL scheme."))
        }
        Log("Opening player URL scheme.")
        guard NSWorkspace.shared.open(u) else { throw ProcessesError.openFailed(String(localized: "Player URL scheme was rejected")) }
    }
}


extension Process {
	@discardableResult
	static func run(_ cmd: [String], at currentDir: URL? = nil, wait: Bool = true) -> (process: Process, outText: String?, errText: String?) {
		guard cmd.count > 0 else {
			fatalError("Process.launch: the command should not be empty")
		}
		
		let (stdout, stderr) = (Pipe(), Pipe())
		let process = Process()
		process.executableURL = URL(fileURLWithPath: cmd[0])
		process.currentDirectoryURL = currentDir ?? Bundle.main.resourceURL
		
		process.arguments = [String](cmd.dropFirst())
		process.standardOutput = stdout
		process.standardError = stderr
		process.launch()
	
		guard wait else {
			return (process, nil, nil)
		}
		
		process.waitUntilExit()
		
		let outText = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
		let errText = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
		
		return (process, outText, errText)
	}
}

/// Per-screen latest-request ownership; shared decoder work is not cancelled by another screen.
@MainActor
final class VideoInspectionSession {
    private let decoder: VideoDecoder
    private var inspectionTask: Task<VideoInspection, any Error>?
    private var inspectionID: UUID?

    init(decoder: VideoDecoder) { self.decoder = decoder }

    func inspectURL(_ url: String, directly: Bool = false) async throws -> VideoInspection {
        inspectionTask?.cancel()
        let id = UUID()
        inspectionID = id
        let task = Task { try await decoder.inspect(url, directly: directly) }
        inspectionTask = task
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard inspectionID == id else { throw CancellationError() }
            inspectionTask = nil
            inspectionID = nil
            return result
        } catch {
            let cancelled = task.isCancelled || Task.isCancelled || inspectionID != id
            if inspectionID == id {
                inspectionTask = nil
                inspectionID = nil
            }
            if cancelled { throw CancellationError() }
            throw error
        }
    }
    
    
    func stopDecodeURL() {
        inspectionTask?.cancel()
        inspectionTask = nil
        inspectionID = nil
    }
}
