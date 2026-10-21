//
//  NIOHTTPServer.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket
import NIOConcurrencyHelpers

struct HTTPServerEndpoint: Equatable, Sendable {
    let host: String
    let port: Int

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}

enum UpgradeResult {
    case websocket(NIOAsyncChannel<WebSocketFrame, WebSocketFrame>)
    case notUpgraded(NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>)
}

final class HTTPByteBufferResponsePartHandler: ChannelOutboundHandler {
    typealias OutboundIn = HTTPPart<HTTPResponseHead, ByteBuffer>
    typealias OutboundOut = HTTPServerResponsePart

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = Self.unwrapOutboundIn(data)
        switch part {
        case .head(let head):
            context.write(Self.wrapOutboundOut(.head(head)), promise: promise)
        case .body(let buffer):
            context.write(Self.wrapOutboundOut(.body(.byteBuffer(buffer))), promise: promise)
        case .end(let trailers):
            context.write(Self.wrapOutboundOut(.end(trailers)), promise: promise)
        }
    }
}

private final class HTTPChildChannelRegistry: @unchecked Sendable {
    private let channels = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])

    func insert(_ channel: Channel) {
        channels.withLockedValue { $0[ObjectIdentifier(channel)] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.channels.withLockedValue { $0.removeValue(forKey: ObjectIdentifier(channel)) }
        }
    }

    func closeAll() -> [Channel] {
        channels.withLockedValue { values in
            let current = Array(values.values)
            values.removeAll(keepingCapacity: true)
            return current
        }
    }
}

private struct BoundHTTPServer {
    let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never>
    let endpoint: HTTPServerEndpoint
}

actor NIOHTTPServer {
    private let decoder: VideoDecoder
    private let streamingService: TorrentStreamingService
    private let portProvider: @MainActor @Sendable () -> Int
    private let enableDanmaku: @MainActor @Sendable () -> Bool
    private let group = MultiThreadedEventLoopGroup.singleton
    private let childChannels = HTTPChildChannelRegistry()

    private var serverChannel: Channel?
    private var endpoint: HTTPServerEndpoint?
    private var acceptLoopTask: Task<Void, Never>?
    private var startupTask: Task<HTTPServerEndpoint, Error>?
    private var generation: UInt64 = 0
    private var shutdownTask: Task<Void, Never>?

    init(
        decoder: VideoDecoder,
        streamingService: TorrentStreamingService,
        portProvider: @escaping @MainActor @Sendable () -> Int,
        enableDanmaku: @escaping @MainActor @Sendable () -> Bool
    ) {
        self.decoder = decoder
        self.streamingService = streamingService
        self.portProvider = portProvider
        self.enableDanmaku = enableDanmaku
    }

    func start() async throws -> HTTPServerEndpoint {
        if let shutdownTask {
            await shutdownTask.value
            self.shutdownTask = nil
        }
        if let endpoint, let serverChannel, serverChannel.isActive {
            return endpoint
        }
        if let startupTask {
            return try await startupTask.value
        }

        let startGeneration = generation
        let task = Task { try await performStart(generation: startGeneration) }
        startupTask = task
        do {
            let endpoint = try await task.value
            if startGeneration == generation { startupTask = nil }
            return endpoint
        } catch {
            if startGeneration == generation { startupTask = nil }
            throw error
        }
    }

    func stop() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        let task = Task { await performStop() }
        shutdownTask = task
        await task.value
        shutdownTask = nil
    }

    private func performStart(generation startGeneration: UInt64) async throws -> HTTPServerEndpoint {
        let port = await portProvider()
        guard startGeneration == generation else { throw CancellationError() }
        let bound = try await Self.bind(port: port, group: group, childChannels: childChannels)
        let manager = await MainActor.run { DanmakuSessionManager(decoder: decoder) }
        guard startGeneration == generation else {
            bound.channel.channel.close(mode: .all, promise: nil)
            try? await bound.channel.channel.closeFuture.get()
            throw CancellationError()
        }

        let handler = HTTPHandler(
            decoder: decoder,
            streamingService: streamingService,
            endpoint: bound.endpoint,
            enableDanmaku: enableDanmaku
        )
        serverChannel = bound.channel.channel
        endpoint = bound.endpoint
        acceptLoopTask = Task {
            do {
                try await bound.channel.executeThenClose { inbound, _ in
                    try await withThrowingTaskGroup(of: Void.self) { connections in
                        for try await result in inbound {
                            connections.addTask {
                                await Self.handleConnection(result, manager: manager, handler: handler)
                            }
                        }
                    }
                }
            } catch {
                Log("NIOHTTPServer accept loop ended: \(error)")
            }
            await self.acceptLoopEnded(on: bound.channel.channel)
        }
        return bound.endpoint
    }

    private func performStop() async {
        generation &+= 1
        let pendingStartup = startupTask
        startupTask = nil

        let listener = serverChannel
        let acceptLoop = acceptLoopTask
        serverChannel = nil
        endpoint = nil
        acceptLoopTask = nil

        listener?.close(mode: .all, promise: nil)
        if let listener {
            try? await listener.closeFuture.get()
        }

        var activeChannels = childChannels.closeAll()
        for channel in activeChannels {
            channel.close(mode: .all, promise: nil)
        }
        for channel in activeChannels {
            try? await channel.closeFuture.get()
        }
        await acceptLoop?.value

        if let pendingStartup {
            _ = try? await pendingStartup.value
        }

        activeChannels = childChannels.closeAll()
        for channel in activeChannels {
            channel.close(mode: .all, promise: nil)
        }
        for channel in activeChannels {
            try? await channel.closeFuture.get()
        }
    }

    private func acceptLoopEnded(on channel: Channel) {
        guard serverChannel === channel else { return }
        serverChannel = nil
        endpoint = nil
        acceptLoopTask = nil
    }

    private static func bind(
        port: Int,
        group: EventLoopGroup,
        childChannels: HTTPChildChannelRegistry
    ) async throws -> BoundHTTPServer {
        let channel: NIOAsyncChannel<EventLoopFuture<UpgradeResult>, Never> = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port) { channel in
                childChannels.insert(channel)
                return channel.eventLoop.makeCompletedFuture {
                    let upgrader = NIOTypedWebSocketServerUpgrader<UpgradeResult>(
                        shouldUpgrade: { channel, _ in
                            channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        },
                        upgradePipelineHandler: { channel, _ in
                            channel.eventLoop.makeCompletedFuture {
                                let asyncChannel = try NIOAsyncChannel<WebSocketFrame, WebSocketFrame>(
                                    wrappingChannelSynchronously: channel
                                )
                                return UpgradeResult.websocket(asyncChannel)
                            }
                        }
                    )

                    let config = NIOTypedHTTPServerUpgradeConfiguration(
                        upgraders: [upgrader],
                        notUpgradingCompletionHandler: { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(HTTPByteBufferResponsePartHandler())
                                let asyncChannel = try NIOAsyncChannel<
                                    HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>
                                >(wrappingChannelSynchronously: channel)
                                return UpgradeResult.notUpgraded(asyncChannel)
                            }
                        }
                    )
                    return try channel.pipeline.syncOperations.configureUpgradableHTTPServerPipeline(
                        configuration: .init(upgradeConfiguration: config)
                    )
                }
            }

        guard let address = channel.channel.localAddress,
              let boundPort = address.port else {
            channel.channel.close(mode: .all, promise: nil)
            throw HTTPServerError.missingBoundAddress
        }
        let endpoint = HTTPServerEndpoint(host: address.ipAddress ?? "127.0.0.1", port: boundPort)
        Log("NIOHTTPServer started on \(address)")
        return BoundHTTPServer(channel: channel, endpoint: endpoint)
    }

    private static func handleConnection(
        _ upgradeResult: EventLoopFuture<UpgradeResult>,
        manager: DanmakuSessionManager,
        handler: HTTPHandler
    ) async {
        do {
            switch try await upgradeResult.get() {
            case .websocket(let wsChannel):
                Log("NIOHTTPServer accepting websocket connection")
                let session = WebSocketSession(asyncChannel: wsChannel, manager: manager)
                await session.handle()
            case .notUpgraded(let httpChannel):
                Log("NIOHTTPServer accepting http connection")
                try await handler.handleChannel(httpChannel)
            }
        } catch {
            Log("NIOHTTPServer connection error: \(error)")
        }
    }
}

enum HTTPServerError: Error {
    case missingBoundAddress
}
