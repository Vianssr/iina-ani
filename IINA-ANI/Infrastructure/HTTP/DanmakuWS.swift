//
//  DanmakuWS.swift
//  IINA+
//
//  Created by xjbeta on 2024/11/25.
//  Copyright © 2024 xjbeta. All rights reserved.
//

import Foundation
import WebKit

enum DanamkuMethod: String, Encodable {
    case start,
    stop,
    initDM,
    resize,
    customFont,
    loadDM,
    sendDM,
    liveDMServer,
    dmSpeed,
    dmOpacity,
    dmFontSize,
    dmBlockList,
    dmSettings
}


struct DanmakuComment: Encodable {
    var text: String
    var imageSrc: String?
    var imageWidth: Int?
    var color: Int?
    var mode: Int?
    var fontSize: Int?
}

struct DanmakuEvent: Encodable {
    var method: DanamkuMethod
    var text: String
    
    var dms: [DanmakuComment]?
    
    func string() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}


protocol DanmakuWSDelegate {
    @MainActor
    func writeDanmakuEventText(contextName: String, _ string: String)
}

struct DanmakuWS {
    var id: String
    var site: SupportSites
    var url: String
    var contextName: String
    var version = 0
    
    var delegate: DanmakuWSDelegate? = nil
    var webview: WKWebView? = nil
    
    
    @MainActor
    func send(_ event: DanmakuEvent) {
        // Old IINA integrations only understand their original individual events.
        guard event.method != .dmSettings || version >= 2 else { return }
        switch version {
        case 0 where event.method == .sendDM:
            event.dms?.forEach {
                let de = DanmakuEvent(method: .sendDM, text: $0.text)
                guard let str = de.string() else { return }
                delegate?.writeDanmakuEventText(contextName: contextName, str)
            }
        default:
            guard let str = event.string() else { return }
            if let delegate {
                delegate.writeDanmakuEventText(contextName: contextName, str)
            } else if let wv = webview {
                wv.evaluateJavaScript("window.dmMessage(\(str));") { _,_ in }
            }
            
            if !str.contains("sendDM") {
                Log("WriteText to [\(id)] \(str)")
            }
        }
    }
    
    @MainActor
    func synchronizeSettings() {
        let settings = Preferences.shared.danmakuSettings
        if version >= 2 {
            guard let data = try? JSONEncoder().encode(settings),
                  let text = String(data: data, encoding: .utf8) else { return }
            send(.init(method: .dmSettings, text: text))
            return
        }

        // Preserve the v0/v1 wire protocol without interpolating raw font names into CSS.
        func cssString(_ value: String) -> String {
            "\"" + value.unicodeScalars.map { "\\\(String($0.value, radix: 16)) " }.joined() + "\""
        }
        let font = cssString("\(settings.fontFamily) \(settings.fontWeight)")
        let style = ".customFont {color: #fff; font-family: \(font), SimHei, SimSun, Heiti, 'MS Mincho', Meiryo, 'Microsoft YaHei', monospace; font-size: \(settings.fontSize)px; letter-spacing: 0; line-height: 100%; margin: 0; padding: 3px 0 0 0; position: absolute; text-decoration: none; text-shadow: -1px 0 black, 0 1px black, 1px 0 black, 0 -1px black; -webkit-text-size-adjust: none; -ms-text-size-adjust: none; text-size-adjust: none; -webkit-transform: matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1); transform: matrix3d(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1); -webkit-transform-origin: 0% 0%; -ms-transform-origin: 0% 0%; transform-origin: 0% 0%; white-space: pre; word-break: keep-all;}"
        send(.init(method: .customFont, text: style))
        send(.init(method: .dmSpeed, text: "\(settings.speed)"))
        send(.init(method: .dmOpacity, text: "\(settings.opacity)"))
        send(.init(method: .dmBlockList, text: settings.blockTypes.joined(separator: ", ")))
    }
    
    @MainActor
    func loadXMLDM() {
        send(.init(method: .loadDM, text: id))
    }
}
