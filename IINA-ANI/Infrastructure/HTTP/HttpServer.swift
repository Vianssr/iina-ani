//
//  HttpServer.swift
//  iina+
//
//  Created by xjbeta on 2018/10/28.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Foundation

@MainActor
final class HttpServer: NSObject {
    private let nioServer: NIOHTTPServer

    init(
        decoder: VideoDecoder,
        streaming: TorrentStreamingService,
        port: @escaping @MainActor @Sendable () -> Int,
        enableDanmaku: @escaping @MainActor @Sendable () -> Bool
    ) {
        nioServer = NIOHTTPServer(
            decoder: decoder,
            streamingService: streaming,
            portProvider: port,
            enableDanmaku: enableDanmaku
        )
    }

    func start() async throws -> HTTPServerEndpoint {
        try await nioServer.start()
    }

    func stop() async {
        await nioServer.stop()
    }
}
