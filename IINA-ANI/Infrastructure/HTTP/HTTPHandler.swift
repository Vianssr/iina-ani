//
//  HTTPHandler.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//



import Foundation
import NIO
import NIOHTTP1
import HuyaKit

struct HTTPHandler: Sendable {
    private let decoder: VideoDecoder
    private let streamingService: TorrentStreamingService
    private let endpoint: HTTPServerEndpoint
    private let enableDanmaku: @MainActor @Sendable () -> Bool

    init(decoder: VideoDecoder, streamingService: TorrentStreamingService, endpoint: HTTPServerEndpoint,
         enableDanmaku: @escaping @MainActor @Sendable () -> Bool) {
        self.decoder = decoder
        self.streamingService = streamingService
        self.endpoint = endpoint
        self.enableDanmaku = enableDanmaku
    }

    func handleChannel(
        _ channel: NIOAsyncChannel<HTTPServerRequestPart, HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        try await channel.executeThenClose { inbound, outbound in
            var currentURL = ""
            var parameters = [String: String]()
            var currentMethod: HTTPMethod = .UNBIND
            var torrentURI: String?
            var torrentRange: String?

            for try await part in inbound {
                switch part {
                case .head(let head):
                    torrentURI = nil
                    torrentRange = nil
                    if TorrentHTTPHandler.matchesPath(head.uri) {
                        torrentURI = head.uri
                        let rangeValues = head.headers["Range"]
                        torrentRange = rangeValues.isEmpty ? nil : rangeValues.joined(separator: ",")
                        currentURL = ""
                        currentMethod = head.method
                        parameters = [:]
                        continue
                    }
                    let u = head.uri
                    let up = u.split(separator: "?", maxSplits: 1).map(String.init)

                    if up.count == 2 {
                        currentURL = up[0]
                        currentMethod = head.method
                        parameters = self.parseParameters(up[1])
                    } else if up.count == 1, head.method == .GET {
                        currentURL = up[0]
                        currentMethod = head.method
                    } else {
                        currentURL = ""
                        currentMethod = .UNBIND
                        parameters = [:]
                    }

                    Log("HTTP \(head.method) \(currentURL)")

                case .body:
                    break

                case .end:
                    if let uri = torrentURI {
                        try await TorrentHTTPHandler.handle(uri: uri, method: currentMethod, rangeHeader: torrentRange,
                                                            outbound: outbound, channel: channel.channel, streamingService: self.streamingService)
                        torrentURI = nil
                        continue
                    }
                    if currentURL.hasPrefix("/huya/") || currentURL.hasPrefix("/didahd/") {
                        // Cancel an upstream media fetch when the player disconnects.
                        try await self.handleDisconnectableRequest(
                            url: currentURL,
                            method: currentMethod,
                            parameters: parameters,
                            outbound: outbound,
                            closeFuture: channel.channel.closeFuture
                        )
                        return
                    }
                    try await self.handleRequest(
                        url: currentURL,
                        method: currentMethod,
                        parameters: parameters,
                        outbound: outbound
                    )
                }
            }
        }
    }

    /// Race media fetching against client disconnect (channel.closeFuture).
    private func handleDisconnectableRequest(
        url: String,
        method: HTTPMethod,
        parameters: [String: String],
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        closeFuture: EventLoopFuture<Void>
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.handleRequest(url: url, method: method, parameters: parameters, outbound: outbound)
            }
            group.addTask {
                // client disconnect -> channel close -> closeFuture completes
                try await closeFuture.get()
                throw ClientDisconnectedError()
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                throw error
            }
        }
    }

    // MARK: - Request Handling

    private func handleRequest(
        url: String,
        method: HTTPMethod,
        parameters: [String: String],
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        switch (url, method) {
        case ("/video/danmakuurl", .POST):
            guard let url = parameters["url"],
                  let json = try? await decode(url),
                  let key = json.videos.first?.key,
                  let encoder = try? await playbackEncoder(for: json, key: key),
                  let data = encoder.danmakuUrl(key)?.data(using: .utf8) else {
                try await sendBadRequest(outbound: outbound)
                return
            }
            try await sendResponse(outbound: outbound, bodyData: data)

        case ("/video/iinaurl", .POST):
            var type = IINAUrlType.normal
            if let tStr = parameters["type"],
               let t = IINAUrlType(rawValue: tStr) {
                type = t
            }

            guard let url = parameters["url"],
                  let json = try? await decode(url),
                  let key = json.videos.first?.key,
                  let encoder = try? await playbackEncoder(for: json, key: key),
                  let data = encoder.iinaURLScheme(key, type: type)?.data(using: .utf8) else {
                try await sendBadRequest(outbound: outbound)
                return
            }
            try await sendResponse(outbound: outbound, bodyData: data)

        case ("/video", .GET):
            let key = parameters["key"] ?? ""
            guard let url = parameters["url"],
                  let json = try? await decode(url, key: key) else {
                try await sendBadRequest(outbound: outbound)
                return
            }

            let data: Data?
            if parameters["pluginAPI"] == nil {
                let encoder = JSONEncoder()
                encoder.outputFormatting = .prettyPrinted
                data = try? encoder.encode(json)
            } else if let playbackEncoder = try? await playbackEncoder(for: json, key: key) {
                data = playbackEncoder.iinaPlusArgsString(key)?.data(using: .utf8)
            } else {
                data = nil
            }
            guard let data else {
                try await sendBadRequest(outbound: outbound)
                return
            }
            try await sendResponse(outbound: outbound, bodyData: data)
        case (_, .GET) where url.hasPrefix("/didahd/"):
            guard let response = try? await DidahdProxy.shared.response(for: url) else {
                try await sendBadRequest(outbound: outbound)
                return
            }
            try await sendResponse(outbound: outbound, bodyData: response.data,
                                   contentType: response.contentType)

        case ("/danmaku/test.htm", .GET):
            guard let path = Bundle.main.path(forResource: "test", ofType: "htm"),
                  let data = FileManager.default.contents(atPath: path) else { return }
            try await sendResponse(outbound: outbound, bodyData: data)

        case (_, .GET) where url.hasPrefix("/huya/"):
            // Huya .slice proxy (HuyaKit): FLV relay。
            // `.ts` 路线已于 2026-09-15 废弃 —— 实测 FLV 容器在 mpv/ffmpeg 下 0 错误解码，
            // 原始阻塞点是超分档(codecType=2)的私有 slice NAL，与容器无关，且已被
            // 「胶囊档回退同名 H.264/H.265 变体」绕过，故不需要 TS 复用。
            guard let roomId = URL(string: url)?.deletingPathExtension().lastPathComponent,
                  !roomId.isEmpty else {
                try await sendBadRequest(outbound: outbound)
                return
            }
            try await HuyaProxyServer.shared.handleHuyaRequest(
                roomId: roomId,
                outbound: outbound
            )

        case (_, .GET) where url.starts(with: "/video.mp4"):
            guard let path = Bundle.main.path(forResource: "empty", ofType: "m4a"),
                  let data = FileManager.default.contents(atPath: path) else { return }
            try await sendResponse(outbound: outbound, bodyData: data)

        default:
            try await sendBadRequest(outbound: outbound)
        }
    }

    // MARK: - Helpers

    private func decode(_ url: String, key: String = "") async throws -> YouGetJSON? {
        var selection = try await decoder.selection(for: url)
        selection.qualityID = key.isEmpty ? nil : key
        var json = try await decoder.resolve(selection)
        if key.isEmpty, let first = json.videos.first?.key {
            json = try await decoder.prepareVideoUrl(json, first)
        }
        return json
    }
    private func playbackEncoder(for media: YouGetJSON, key: String) async throws -> PlaybackEncoder {
        let requested = await enableDanmaku()
        let enabled = requested && decoder.registry.descriptor(for: media.site.sourceID)?.capabilities.contains(.danmaku) == true
        let context = try PlaybackPreparation.context(for: media, key: key, endpoint: endpoint, enableDanmaku: enabled)
        return PlaybackEncoder(media: media, context: context)
    }

    private func sendResponse(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>,
        bodyData: Data,
        contentType: String? = nil
    ) async throws {
        var newHeaders = HTTPHeaders()
        newHeaders.add(name: "Content-Length", value: "\(bodyData.count)")
        if let contentType { newHeaders.add(name: "Content-Type", value: contentType) }
        newHeaders.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: newHeaders)
        var buffer = ByteBufferAllocator().buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)

        try await outbound.write(contentsOf: [
            .head(head),
            .body(buffer),
            .end(nil),
        ])
    }

    private func parseParameters(_ string: String) -> [String: String] {
        let requestBodys = string.split(separator: "&")
        var parameters = [String: String]()
        requestBodys.forEach {
            let kv = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
            guard kv.count == 2 else { return }
            parameters[kv[0]] = kv[1].removingPercentEncoding
        }
        return parameters
    }

    private func sendBadRequest(
        outbound: NIOAsyncChannelOutboundWriter<HTTPPart<HTTPResponseHead, ByteBuffer>>
    ) async throws {
        let headers = HTTPHeaders([("Connection", "close"), ("Content-Length", "0")])
        let head = HTTPResponseHead(version: .http1_1, status: .badRequest, headers: headers)
        try await outbound.write(contentsOf: [
            .head(head),
            .end(nil),
        ])
    }
}
