import Foundation
import NIO

private enum PlayerProgressEvent: Sendable {
    case progress(Double, Double?)
    case ended(Bool, Bool)
    case queue(LocalQueueIPCEvent)
}

private struct PlayerQueueError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Private socket and media-path gate prevent another player/file from updating this history.
@MainActor
final class PlayerProgressSession {
    let id = UUID()
    let socketURL: URL
    let playlistURL: URL?
    private let initialStartPosition: Double
    private var resetInitialResumeOnReady = false
    private let directory: URL
    private var recorder: PlaybackProgressRecorder
    private let paths: Set<String>
    private let localQueue: [PlayableSelection]
    private let queuePaths: [String]
    private let initialQueueIndex: Int?
    private let makeRecorder: (@MainActor (PlayableSelection) -> PlaybackProgressRecorder)?
    private let queueItemOptions: (@MainActor (PlayableSelection) -> [String: String])?
    private let onQueueEOF: (@MainActor (PlaybackProgressRecorder) async throws -> PlayableSelection?)?
    private var channel: Channel?
    private var monitor: Task<Void, Never>?
    private var eventMonitor: Task<Void, Never>?
    private var eventContinuation: AsyncStream<PlayerProgressEvent>.Continuation?
    private var queueConfiguration: Task<Void, Never>?
    private var eofTask: Task<Void, Never>?
    private var queueConfigured = false
    private var usedInitialRecorder = false
    private var activeIndex: Int?
    private var activeGeneration = 0
    private var pendingAutoplayIndex: Int?
    private var recorderEnded = false
    private var finished = false
    private var nextRequestID = 0
    private struct Request {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }
    private var requests: [Int: Request] = [:]
    private let onFinish: @MainActor (UUID) -> Void
    private let onEOF: @MainActor (PlaybackProgressRecorder) -> Void

    init(recorder: PlaybackProgressRecorder, paths: Set<String>,
         localQueue: [PlayableSelection] = [],
         nativePlaylist: Bool = false,
         initialStartPosition: Double = 0,
         makeRecorder: (@MainActor (PlayableSelection) -> PlaybackProgressRecorder)? = nil,
         onQueueEOF: (@MainActor (PlaybackProgressRecorder) async throws -> PlayableSelection?)? = nil,
         queueItemOptions: (@MainActor (PlayableSelection) -> [String: String])? = nil,
         onEOF: @escaping @MainActor (PlaybackProgressRecorder) -> Void = { _ in },
         onFinish: @escaping @MainActor (UUID) -> Void) throws {
        self.recorder = recorder; self.paths = paths; self.onFinish = onFinish; self.onEOF = onEOF
        self.localQueue = localQueue; self.makeRecorder = makeRecorder
        self.onQueueEOF = onQueueEOF; self.queueItemOptions = queueItemOptions
        self.initialStartPosition = initialStartPosition
        queuePaths = try localQueue.map { selection in
            guard selection.item.sourceID == "local", selection.item.kind == .local,
                  selection.episode == nil, selection.torrent == nil,
                  let url = URL(string: selection.item.pageURL), url.isFileURL else {
                throw PlayerQueueError(message: String(localized: "The player queue contains a non-local selection."))
            }
            return url.path
        }
        initialQueueIndex = localQueue.firstIndex { $0.item == recorder.selection.item }
        if !localQueue.isEmpty {
            guard initialQueueIndex != nil, makeRecorder != nil,
                  Set(queuePaths).count == queuePaths.count else {
                throw PlayerQueueError(message: String(localized: "The player queue requires its selected file, unique paths, and a recorder factory."))
            }
        }
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vp-" + String(id.uuidString.prefix(12)))
        socketURL = directory.appendingPathComponent("ipc")
        playlistURL = nativePlaylist && !localQueue.isEmpty ? directory.appendingPathComponent("episodes.m3u") : nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            if let playlistURL {
                var content = "#EXTM3U\n"
                for selection in localQueue {
                    // File URLs keep newlines and non-ASCII names unambiguous.
                    content += selection.item.pageURL + "\n"
                }
                try Data(content.utf8).write(to: playlistURL, options: .atomic)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func observe() {
        guard monitor == nil, !finished else { return }
        let (events, continuation) = AsyncStream<PlayerProgressEvent>.makeStream()
        eventContinuation = continuation
        // One consumer preserves NIO event order, including path changes before progress/EOF.
        eventMonitor = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                receive(event)
            }
        }
        monitor = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(45)
            var lastError: Error?
            while !Task.isCancelled, !finished, ContinuousClock.now < deadline {
                do {
                    let connection = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                        .connectTimeout(.seconds(1)).channelInitializer { [paths, queuePaths, initialQueueIndex] channel in
                            if let initialQueueIndex {
                                return channel.pipeline.addHandler(LocalQueueIPCHandler(
                                    paths: paths, queuePaths: queuePaths, initialIndex: initialQueueIndex,
                                    event: { continuation.yield(.queue($0)) }))
                            }
                            return channel.pipeline.addHandler(PlaybackIPCHandler(paths: paths, progress: {
                                continuation.yield(.progress($0, $1))
                            }, ended: { continuation.yield(.ended($0, $1)) }))
                        }.connect(unixDomainSocketPath: socketURL.path).get()
                    guard !finished, !Task.isCancelled else { try? await connection.close().get(); return }
                    channel = connection
                    var buffer = connection.allocator.buffer(capacity: 512)
                    buffer.writeString(initialQueueIndex == nil ? PlaybackIPCHandler.observations : LocalQueueIPCHandler.observations)
                    try await connection.writeAndFlush(buffer).get()
                    return
                } catch {
                    lastError = error
                    if channel != nil {
                        await failQueue(error)
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            if !finished {
                NSLog("Player IPC could not be connected; playback progress was not recorded (%@).",
                      lastError.map { String(describing: $0) } ?? "connection timed out")
                await stop()
            }
        }
    }

    func stop() async { await finish(completed: false) }

    private func receive(_ event: PlayerProgressEvent) {
        guard !finished else { return }
        switch event {
        case let .progress(position, duration):
            recorder.update(position: position, duration: duration)
        case let .ended(failed, completed):
            if failed { NSLog("Player failed to load the selected media.") }
            Task { await self.finish(completed: completed) }
        case let .queue(event):
            receiveQueue(event)
        }
    }

    private func receiveQueue(_ event: LocalQueueIPCEvent) {
        switch event {
        case let .reply(id, error):
            resolveRequest(id, error: error == "success" ? nil : PlayerQueueError(message: "mpv IPC: " + error))
        case let .loaded(index, generation):
            if pendingAutoplayIndex != index { pendingAutoplayIndex = nil }
            eofTask?.cancel(); eofTask = nil
            if usedInitialRecorder {
                endRecorder(completed: false)
                guard let makeRecorder else { return }
                recorder = makeRecorder(localQueue[index])
            } else {
                usedInitialRecorder = true
            }
            recorderEnded = false
            activeIndex = index; activeGeneration = generation
        case let .ready(index, generation):
            guard activeIndex == index, activeGeneration == generation else { return }
            if resetInitialResumeOnReady {
                resetInitialResumeOnReady = false
                Task {
                    do { try await command(["set_property", "start", "0"]) }
                    catch { if !finished { await failQueue(error) } }
                }
            }
            if queueConfiguration == nil {
                queueConfiguration = Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await configureQueue(index: index, generation: generation)
                    } catch {
                        if !finished { await failQueue(error) }
                    }
                }
            } else if queueConfigured {
                let unpause = pendingAutoplayIndex == index
                pendingAutoplayIndex = nil
                // The original entry has no appended per-file options; revisits must not
                // inherit the last file's title or the initial command-line start offset.
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await command(["set_property", "start", "0"])
                        guard activeIndex == index, activeGeneration == generation else { return }
                        try await command(["set_property", "force-media-title", options(for: index)["force-media-title"] ?? ""])
                        guard activeIndex == index, activeGeneration == generation else { return }
                        if unpause { try await command(["set_property", "pause", false]) }
                    } catch {
                        if !finished { await failQueue(error) }
                    }
                }
            }
        case let .progress(index, generation, position, duration):
            guard activeIndex == index, activeGeneration == generation, !recorderEnded else { return }
            recorder.update(position: position, duration: duration)
        case let .eof(index, generation):
            guard activeIndex == index, activeGeneration == generation, !recorderEnded else { return }
            endRecorder(completed: true)
            guard let onQueueEOF else { return }
            let completedRecorder = recorder
            eofTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let next = try await onQueueEOF(completedRecorder)
                    if let queueConfiguration { await queueConfiguration.value }
                    guard !finished, !Task.isCancelled, queueConfigured,
                          activeIndex == index, activeGeneration == generation, let next,
                          let nextIndex = localQueue.firstIndex(where: { $0.item == next.item }),
                          next.episode == nil, next.torrent == nil else { return }
                    try await command(["set_property", "start", "0"])
                    guard !finished, !Task.isCancelled, activeIndex == index, activeGeneration == generation else { return }
                    try await command(["set_property", "force-media-title", options(for: nextIndex)["force-media-title"] ?? ""])
                    guard !finished, !Task.isCancelled, activeIndex == index, activeGeneration == generation else { return }
                    // keep-open may re-pause the EOF frame. Unpause only after the
                    // next file is ready, not before its start-file cancels this task.
                    pendingAutoplayIndex = nextIndex
                    try await command(["set_property", "playlist-pos", nextIndex])
                } catch {
                    if !finished, !Task.isCancelled, activeIndex == index, activeGeneration == generation {
                        await failQueue(error)
                    }
                }
            }
        case let .unloaded(generation):
            activeIndex = nil; activeGeneration = generation
            eofTask?.cancel(); eofTask = nil
            endRecorder(completed: false)
        case let .ended(failed, message):
            // Invalidate synchronously, before another queued property/EOF can be consumed.
            activeIndex = nil; activeGeneration += 1
            eofTask?.cancel()
            Task {
                if failed { await self.failQueue(PlayerQueueError(message: message ?? "The queued media failed to load.")) }
                else { await self.stop() }
            }
        }
    }

    private func options(for index: Int) -> [String: String] {
        var options = queueItemOptions?(localQueue[index]) ?? [:]
        options["start"] = "0"
        if options["force-media-title"] == nil {
            options["force-media-title"] = URL(fileURLWithPath: queuePaths[index]).lastPathComponent
        }
        return options
    }

    private func configureQueue(index: Int, generation: Int) async throws {
        // A numeric time-pos/file-loaded means the initial resume option has already
        // been consumed. Merely observing path can happen too early to reset start.
        try await command(["set_property", "keep-open", "always"])
        try await command(["set_property", "loop-file", "no"])
        try await command(["set_property", "loop-playlist", "no"])
        try await command(["set_property", "start", "0"])
        try await command(["set_property", "force-media-title", options(for: index)["force-media-title"] ?? ""])
        try requireCurrent(index: index, generation: generation)
        if playlistURL != nil, let referrer = options(for: index)["referrer"], !referrer.isEmpty {
            // M3U cannot carry mpv per-file options. Reload only when the selected
            // episode needs its own XML payload, retaining the requested resume.
            var initialOptions = options(for: index)
            initialOptions.removeValue(forKey: "start")
            try await command(["set_property", "start", String(initialStartPosition)])
            resetInitialResumeOnReady = true
            try await command(["name": "loadfile", "url": queuePaths[index],
                               "flags": "replace", "options": initialOptions] as [String: Any])
        } else {
            // playlist-clear retains the currently playing file, without reloading it.
            try await command(["playlist-clear"])
        }
        // Once cleared, entry zero is known even if the user selects an appended
        // item while the remaining files are being added. Reordering never reloads it.
        for other in localQueue.indices where other != index {
            try await command(["name": "loadfile", "url": queuePaths[other],
                               "flags": "append", "options": options(for: other)] as [String: Any])
        }
        if index != 0 { try await command(["playlist-move", 0, index + 1]) }
        queueConfigured = true
    }

    private func requireCurrent(index: Int, generation: Int) throws {
        guard !finished, activeIndex == index, activeGeneration == generation else {
            throw PlayerQueueError(message: String(localized: "The selected media changed before its player queue could be initialized."))
        }
    }

    private func command(_ command: Any) async throws {
        guard !finished, let channel else { throw PlayerQueueError(message: String(localized: "The player IPC connection is closed.")) }
        nextRequestID += 1
        let requestID = nextRequestID
        let data = try JSONSerialization.data(withJSONObject: ["command": command, "request_id": requestID])
        var buffer = channel.allocator.buffer(capacity: data.count + 1)
        buffer.writeBytes(data); buffer.writeInteger(UInt8(10))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.resolveRequest(requestID, error: PlayerQueueError(message: String(localized: "The player did not acknowledge IPC request \(requestID).")))
            }
            requests[requestID] = Request(continuation: continuation, timeout: timeout)
            channel.writeAndFlush(buffer).whenFailure { [weak self] error in
                Task { @MainActor in self?.resolveRequest(requestID, error: error) }
            }
        }
    }

    private func resolveRequest(_ id: Int, error: Error?) {
        guard let request = requests.removeValue(forKey: id) else { return }
        request.timeout.cancel()
        if let error { request.continuation.resume(throwing: error) }
        else { request.continuation.resume() }
    }

    private func endRecorder(completed: Bool) {
        guard !recorderEnded else { return }
        recorderEnded = true
        recorder.finish(completed: completed)
    }

    private func failQueue(_ error: Error) async {
        guard !finished else { return }
        NSLog("Player queue could not be maintained: %@", error.localizedDescription)
        await finish(completed: false, stopPlayer: true)
    }

    private func finish(completed: Bool, stopPlayer: Bool = false) async {
        guard !finished else { return }
        finished = true
        endRecorder(completed: completed)
        monitor?.cancel(); monitor = nil
        queueConfiguration?.cancel(); queueConfiguration = nil
        eofTask?.cancel(); eofTask = nil
        for id in Array(requests.keys) { resolveRequest(id, error: CancellationError()) }
        if let channel {
            if stopPlayer {
                // A failed load must not let mpv skip forward into another queued file.
                do {
                    var buffer = channel.allocator.buffer(capacity: 128)
                    let commands: [[Any]] = [["set_property", "pause", true], ["stop"]]
                    for command in commands {
                        buffer.writeBytes(try JSONSerialization.data(withJSONObject: ["command": command]))
                        buffer.writeInteger(UInt8(10))
                    }
                    try await channel.writeAndFlush(buffer).get()
                } catch { NSLog("Player could not be stopped after its queue failed: %@", error.localizedDescription) }
            }
            try? await channel.close().get()
            self.channel = nil
        }
        eventContinuation?.finish(); eventContinuation = nil
        eventMonitor?.cancel(); eventMonitor = nil
        try? FileManager.default.removeItem(at: directory)
        onFinish(id)
        // Queue EOF retains this socket/window; only nonqueue clients launch successors.
        if completed, localQueue.isEmpty { onEOF(recorder) }
    }
}

/// Confined to the NIO event loop, with bounded framing and no payload logging.
final class PlaybackIPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    static let observations = ["path", "idle-active", "time-pos", "paused-for-cache", "duration"].enumerated().map {
        "{\"command\":[\"observe_property\",\($0.offset + 1),\"\($0.element)\"]}\n"
    }.joined()
    private var pending = ByteBuffer()
    private let paths: Set<String>
    private let started: @Sendable () -> Void
    private let buffering: @Sendable (Bool) -> Void
    private let progress: @Sendable (Double, Double?) -> Void
    private let ended: @Sendable (Bool, Bool) -> Void
    private var seenMedia = false
    private var notified = false
    private var notifiedStarted = false
    private var position: Double?
    private var duration: Double?

    init(paths: Set<String>, started: @escaping @Sendable () -> Void = {},
         buffering: @escaping @Sendable (Bool) -> Void = { _ in },
         progress: @escaping @Sendable (Double, Double?) -> Void,
         ended: @escaping @Sendable (Bool, Bool) -> Void) {
        self.paths = paths; self.started = started; self.buffering = buffering
        self.progress = progress; self.ended = ended
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard pending.readableBytes + bytes.readableBytes <= 65_536 else { finish(failed: true); context.close(promise: nil); return }
        pending.writeBuffer(&bytes)
        while let newline = pending.readableBytesView.firstIndex(of: 10) {
            let count = newline - pending.readerIndex
            guard let line = pending.readBytes(length: count) else { break }
            pending.moveReaderIndex(forwardBy: 1)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            receive(message)
        }
        pending.discardReadBytes()
    }

    /// Event-loop confined state transition, shared by the framed transport and regressions.
    func receive(_ message: [String: Any]) {
        guard !notified else { return }
        let event = message["event"] as? String
        if event == "property-change", let name = message["name"] as? String {
            if name == "path", let path = message["data"] as? String {
                let filePath = URL(string: path).flatMap { $0.isFileURL ? $0.path : nil }
                if paths.contains(path) || filePath.map(paths.contains) == true { seenMedia = true }
                else if seenMedia { finish(); return }
            }
            guard seenMedia else { return }
            if name == "paused-for-cache", let value = message["data"] as? Bool { buffering(value) }
            if name == "duration", let value = message["data"] as? Double, value.isFinite, value > 0 {
                duration = value
                if let position { progress(position, duration) }
            }
            if name == "time-pos", let value = message["data"] as? Double, value.isFinite, value >= 0 {
                position = value
                if !notifiedStarted { notifiedStarted = true; started() }
                progress(value, duration)
            }
            if name == "idle-active", message["data"] as? Bool == true { finish() }
        }
        if event == "end-file", seenMedia, message["reason"] as? String != "redirect" {
            finish(failed: message["reason"] as? String == "error", completed: message["reason"] as? String == "eof")
        }
        if event == "shutdown" { finish() }
    }
    func channelInactive(context: ChannelHandlerContext) { finish(); context.fireChannelInactive() }
    func errorCaught(context: ChannelHandlerContext, error: Error) { finish(failed: true); context.close(promise: nil) }
    private func finish(failed: Bool = false, completed: Bool = false) {
        guard !notified else { return }
        notified = true; ended(failed, completed)
    }
}

enum LocalQueueIPCEvent: Sendable {
    case loaded(index: Int, generation: Int)
    case ready(index: Int, generation: Int)
    case progress(index: Int, generation: Int, position: Double, duration: Double?)
    case eof(index: Int, generation: Int)
    case unloaded(generation: Int)
    case reply(id: Int, error: String)
    case ended(failed: Bool, message: String?)
}

/// Queue loads are generations, not separate connections. Only a matched local path
/// can own progress or EOF, and a start/stop invalidates any older asynchronous choice.
final class LocalQueueIPCHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    static let observations = ["path", "idle-active", "time-pos", "duration", "eof-reached"].enumerated().map {
        "{\"command\":[\"observe_property\",\($0.offset + 1),\"\($0.element)\"]}\n"
    }.joined()
    private var pending = ByteBuffer()
    private let paths: Set<String>
    private let queuePaths: [String]
    private let initialIndex: Int
    private let event: @Sendable (LocalQueueIPCEvent) -> Void
    private var seenInitial = false
    private var notified = false
    private var index: Int?
    private var generation = 0
    private var position: Double?
    private var duration: Double?
    private var ready = false
    private var fileLoaded = false
    private var notifiedEOF = false

    init(paths: Set<String>, queuePaths: [String], initialIndex: Int,
         event: @escaping @Sendable (LocalQueueIPCEvent) -> Void) {
        self.paths = paths; self.queuePaths = queuePaths
        self.initialIndex = initialIndex; self.event = event
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var bytes = unwrapInboundIn(data)
        guard pending.readableBytes + bytes.readableBytes <= 65_536 else {
            finish(failed: true, message: String(localized: "The player IPC exceeded its message limit."))
            context.close(promise: nil)
            return
        }
        pending.writeBuffer(&bytes)
        while let newline = pending.readableBytesView.firstIndex(of: 10) {
            let count = newline - pending.readerIndex
            guard let line = pending.readBytes(length: count) else { break }
            pending.moveReaderIndex(forwardBy: 1)
            guard let message = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            receive(message)
        }
        pending.discardReadBytes()
    }

    func receive(_ message: [String: Any]) {
        if let requestID = message["request_id"] as? Int, let error = message["error"] as? String {
            event(.reply(id: requestID, error: error))
        }
        guard !notified else { return }
        switch message["event"] as? String {
        case "start-file":
            invalidate()
        case "file-loaded":
            fileLoaded = true
            signalReady()
        case "property-change":
            receiveProperty(message)
        case "end-file":
            switch message["reason"] as? String {
            case "redirect":
                break
            case "error":
                let reason = message["file_error"] as? String ?? String(localized: "unknown media error")
                finish(failed: true, message: String(localized: "mpv could not load a queued file (\(reason))."))
            case "eof":
                signalReady()
                signalEOF()
            case "quit":
                finish()
            default:
                // Manual next/previous also produces reason=stop. Retire its recorder,
                // but retain the socket until the following path or actual idle/close.
                invalidate()
            }
        case "shutdown":
            finish()
        default:
            break
        }
    }

    private func receiveProperty(_ message: [String: Any]) {
        guard let name = message["name"] as? String else { return }
        if name == "path", let path = message["data"] as? String {
            let fileURL = URL(string: path).flatMap { $0.isFileURL ? $0 : nil }
            let filePath = fileURL?.path ?? path
            let matched = queuePaths.firstIndex(of: filePath)
            if !seenInitial {
                guard matched == initialIndex,
                      paths.contains(path) || paths.contains(filePath) ||
                        paths.contains(URL(fileURLWithPath: filePath).absoluteString) else { return }
                seenInitial = true
            }
            guard let matched else { finish(); return }
            if index != matched {
                if index != nil { invalidate() }
                index = matched
                event(.loaded(index: matched, generation: generation))
                if fileLoaded { signalReady() }
            }
        }
        guard seenInitial else { return }
        if name == "idle-active", message["data"] as? Bool == true {
            finish()
            return
        }
        guard let index else { return }
        if name == "time-pos", let value = message["data"] as? Double, value.isFinite, value >= 0 {
            position = value
            signalReady()
            event(.progress(index: index, generation: generation, position: value, duration: duration))
        } else if name == "duration", let value = message["data"] as? Double, value.isFinite, value > 0 {
            duration = value
            if let position { event(.progress(index: index, generation: generation, position: position, duration: value)) }
        } else if name == "eof-reached", message["data"] as? Bool == true {
            signalReady()
            signalEOF()
        }
    }

    private func signalReady() {
        guard let index, !ready else { return }
        ready = true
        event(.ready(index: index, generation: generation))
    }

    private func signalEOF() {
        guard let index, !notifiedEOF else { return }
        notifiedEOF = true
        event(.eof(index: index, generation: generation))
    }

    private func invalidate() {
        generation += 1
        if seenInitial { event(.unloaded(generation: generation)) }
        index = nil; position = nil; duration = nil
        ready = false; fileLoaded = false; notifiedEOF = false
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(failed: true, message: error.localizedDescription)
        context.close(promise: nil)
    }

    private func finish(failed: Bool = false, message: String? = nil) {
        guard !notified else { return }
        notified = true
        event(.ended(failed: failed, message: message))
    }
}
