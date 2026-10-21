import Foundation
import NIO

/// One private IPC endpoint per playback; no player-wide quit or shared socket.
@MainActor
final class TorrentPlayerSession {
    let grant: TorrentPlaybackGrant
    let socketURL: URL
    enum State: Sendable, Equatable { case connecting, buffering, playing, stopped, failed(String) }
    private(set) var state: State = .connecting
    private let directory: URL
    private var connection: Channel?
    private var monitor: Task<Void, Never>?
    private var finished = false
    private var loaded = false
    private let onFinish: @MainActor (UUID) -> Void
    private let streaming: TorrentStreamingService
    private let recorder: PlaybackProgressRecorder?

    init(grant: TorrentPlaybackGrant, streaming: TorrentStreamingService, recorder: PlaybackProgressRecorder? = nil, onFinish: @escaping @MainActor (UUID) -> Void) throws {
        self.grant = grant
        self.streaming = streaming
        self.onFinish = onFinish
        self.recorder = recorder
        // Keep below sockaddr_un's 104-byte path limit, even with a long user home.
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bt-" + String(UUID().uuidString.prefix(12)))
        socketURL = directory.appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    func observe() {
        monitor = Task { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(45)
            while !Task.isCancelled, !finished, ContinuousClock.now < deadline {
                do {
                    let handler = PlaybackIPCHandler(paths: [grant.url.absoluteString], started: { [weak self] in
                        Task { @MainActor in self?.loaded = true; self?.state = .playing }
                    }, buffering: { [weak self] buffering in
                        Task { @MainActor in self?.state = buffering ? .buffering : .playing }
                    }, progress: { [weak self] position, duration in
                        Task { @MainActor in self?.recorder?.update(position: position, duration: duration) }
                    }, ended: { [weak self] failed, completed in
                        Task { @MainActor in
                            if failed { self?.state = .failed(String(localized: "播放器無法讀取 Torrent 串流。")) }
                            self?.recorder?.finish(completed: completed)
                            await self?.stop(sendStop: false)
                        }
                    })
                    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                        .connectTimeout(.seconds(1))
                        .channelInitializer { channel in channel.pipeline.addHandler(handler) }
                        .connect(unixDomainSocketPath: socketURL.path).get()
                    guard !finished, !Task.isCancelled else { try? await channel.close().get(); return }
                    connection = channel
                    var buffer = channel.allocator.buffer(capacity: 160)
                    buffer.writeString(PlaybackIPCHandler.observations)
                    try await channel.writeAndFlush(buffer).get()
                    try await Task.sleep(for: .seconds(45))
                    if !loaded { state = .failed(String(localized: "播放器未在期限內載入媒體。請檢查 peers 與播放器。 ")); await stop() }
                    return
                } catch {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
            }
            if !finished { state = .failed(String(localized: "無法連接播放器 IPC。 ")); await stop(sendStop: false) }
        }
    }

    func stop(sendStop: Bool = true) async {
        guard !finished else { return }
        finished = true
        recorder?.finish()
        if case .failed = state {} else { state = .stopped }
        monitor?.cancel()
        monitor = nil
        if let connection {
            if sendStop {
                var buffer = connection.allocator.buffer(capacity: 24)
                buffer.writeString("{\"command\":[\"stop\"]}\n")
                try? await connection.writeAndFlush(buffer).get()
            }
            try? await connection.close().get()
            self.connection = nil
        }
        await streaming.revoke(grant.id)
        try? FileManager.default.removeItem(at: directory)
        onFinish(grant.id)
    }
}

