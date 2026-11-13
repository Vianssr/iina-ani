//
//  WebSocketDanmakuHandler.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Foundation
import NIO
import NIOWebSocket

actor WebSocketSession {
    private let asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    private var outboundWriter: NIOAsyncChannelOutboundWriter<WebSocketFrame>?
    private var awaitingClose = false
    let contextName: String
    private let manager: DanmakuSessionManager

    init(
        asyncChannel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>,
        manager: DanmakuSessionManager
    ) {
        self.asyncChannel = asyncChannel
        self.contextName = UUID().uuidString
        self.manager = manager
    }

    func handle() async {
        Log("Websocket client connected. \(contextName)")
        await manager.sessionStarted(self)

        do {
            try await asyncChannel.executeThenClose { inbound, outbound in
                self.outboundWriter = outbound

                for try await frame in inbound {
                    switch frame.opcode {
                    case .connectionClose:
                        await self.receivedClose(frame: frame)
                        return
                    case .ping:
                        try await self.pong(frame: frame)
                    case .text:
                        var data = frame.unmaskedData
                        let text = data.readString(length: data.readableBytes) ?? ""
                        await manager.textReceived(text, contextName: self.contextName)
                    case .binary, .continuation, .pong:
                        break
                    default:
                        await self.closeOnError()
                    }
                }
            }
        } catch is CancellationError {
        } catch {
            Log("WebSocket session error: \(error)")
        }

        await manager.sessionEnded(self)
        Log("Websocket client disconnected.")
    }

    func writeText(_ string: String) async {
        guard !awaitingClose else { return }
        var buffer = ByteBufferAllocator().buffer(capacity: string.utf8.count)
        buffer.writeString(string)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        try? await outboundWriter?.write(frame)
    }

    // MARK: - Private

    private func receivedClose(frame: WebSocketFrame) async {
        if awaitingClose {
            return
        }
        var data = frame.unmaskedData
        let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
        let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
        try? await outboundWriter?.write(closeFrame)
    }

    private func pong(frame: WebSocketFrame) async throws {
        var frameData = frame.data
        if let maskingKey = frame.maskKey {
            frameData.webSocketUnmask(maskingKey)
        }
        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        try await outboundWriter?.write(responseFrame)
    }

    private func closeOnError() async {
        var data = ByteBufferAllocator().buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        try? await outboundWriter?.write(frame)
        awaitingClose = true
    }
}

@MainActor
final class DanmakuSessionManager: NSObject, DanmakuDelegate, DanmakuWSDelegate {
    private let decoder: VideoDecoder
    private var connectedItems: [String: DanmakuWS] = [:]
    private var danmakus = [Danmaku]()
    private var sessions: [String: WebSocketSession] = [:]

    init(decoder: VideoDecoder) {
        self.decoder = decoder
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged),
            name: Preferences.danmakuSettingsDidChangeNotification, object: Preferences.shared)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Session lifecycle

    func sessionStarted(_ session: WebSocketSession) {
        sessions[session.contextName] = session
    }

    func sessionEnded(_ session: WebSocketSession) {
        let contextName = session.contextName
        sessions.removeValue(forKey: contextName)
        connectedItems.removeValue(forKey: contextName)
        stopUnusedDanmakus()
    }

    // MARK: - Text handling

    func textReceived(_ text: String, contextName: String) {
        var clickType: IINAUrlType = .none

        let ws: DanmakuWS? = {
            if text.starts(with: "iinaDM://") {
                clickType = .plugin
                var v = 0
                var u = String(text.dropFirst("iinaDM://".count))

                if u.starts(with: "v=") {
                    let vu = u.split(separator: "&", maxSplits: 1)
                    guard vu.count == 2 else { return nil }
                    v = Int(vu[0].dropFirst(2)) ?? 0
                    u = String(vu[1])
                }

                var re = DanmakuWS(id: u,
                                   site: .init(url: u),
                                   url: u,
                                   contextName: contextName)
                re.version = v
                return re
            } else if text.starts(with: "iinaWebDM://") {
                let hex = String(text.dropFirst("iinaWebDM://".count))
                clickType = .danmaku
                guard let ids = String(data: Data(hex: hex), encoding: .utf8)?.split(separator: "👻").map(String.init),
                      ids.count == 2 else { return nil }
                let u = ids[1]

                var re = DanmakuWS(id: ids[0],
                                   site: .init(url: u),
                                   url: u,
                                   contextName: contextName)
                // This scheme belongs to the bundled renderer, which consumes atomic settings.
                re.version = 2
                return re
            } else {
                return nil
            }
        }()

        guard var ws else { return }

        ws.delegate = self
        connectedItems.removeValue(forKey: contextName)
        switch clickType {
        case .danmaku:
            if [.bilibili, .bangumi, .b23].contains(ws.site) {
                connectedItems[contextName] = ws
                ws.synchronizeSettings()
                ws.loadXMLDM()
            } else if ws.site != .unsupported {
                connectedItems[contextName] = ws
                ws.synchronizeSettings()
                loadNewDanmaku(ws)
            }
        case .plugin where ws.version >= 2 && ws.url == "settings":
            // XML remains loaded by the plugin; this session only receives preferences.
            connectedItems[contextName] = ws
            ws.synchronizeSettings()
        case .plugin where ![.unsupported, .bangumi, .bilibili, .b23].contains(ws.site):
            connectedItems[contextName] = ws
            ws.synchronizeSettings()
            loadNewDanmaku(ws)
        case .plugin:
            connectedItems[contextName] = ws
            ws.synchronizeSettings()
        default:
            break
        }
        stopUnusedDanmakus()
    }

    // MARK: - DanmakuDelegate

    func send(_ event: DanmakuEvent, sender: Danmaku) {
        connectedItems.values.filter { $0.url == sender.url }.forEach {
            $0.send(event)
        }
    }

    // MARK: - DanmakuWSDelegate

    func writeDanmakuEventText(contextName: String, _ string: String) {
        guard let session = sessions[contextName] else { return }
        Task {
            await session.writeText(string)
        }
    }

    // MARK: - Private

    @objc private func settingsChanged() {
        connectedItems.values.forEach { $0.synchronizeSettings() }
    }

    private func stopUnusedDanmakus() {
        let activeURLs = Set(connectedItems.values.map { $0.url })
        danmakus.removeAll { dm in
            guard !activeURLs.contains(dm.url) else { return false }
            dm.stop()
            return true
        }
    }

    private func loadNewDanmaku(_ ws: DanmakuWS) {
        guard !danmakus.contains(where: { $0.url == ws.url }) else { return }
        let d = Danmaku(ws.url, decoder: decoder)
        d.id = ws.url
        d.delegate = self
        danmakus.append(d)
        Task { await d.loadDM() }
    }
}
