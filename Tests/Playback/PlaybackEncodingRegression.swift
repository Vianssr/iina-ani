import Foundation
@testable import IINA_ANI

@main enum PlaybackEncodingRegression {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    static func pluginPayload(_ encoder: PlaybackEncoder, key: String) throws -> [String: Any] {
        guard let hex = encoder.iinaPlusArgsString(key) else { throw Failure(message: "Missing plugin payload") }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw Failure(message: "Invalid hex payload") }
            bytes.append(byte)
            index = next
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            throw Failure(message: "Invalid plugin JSON")
        }
        return object
    }

    static func main() throws {
        let endpoint = HTTPServerEndpoint(host: "127.0.0.1", port: 43210)
        let alternative = "https://media.invalid/watch.mp4?token=a%2Bb&title=%E5%8B%95%E7%95%AB"
        var media = YouGetJSON(url: "https://media.invalid/primary.mp4")
        media.site = .bilibili
        media.title = "動畫 & test"
        media.streams["url"]?.src = [alternative]
        media.selection = PlayableSelection(item: SourceItemRef(sourceID: "bilibili", pageURL: "https://www.bilibili.com/video/BV1", kind: .video), lineID: "1", qualityID: "url")
        let context = PlaybackEncodingContext(endpoint: endpoint, enableDanmaku: true, danmakuFile: nil)
        let encoder = PlaybackEncoder(media: media, context: context)
        try require(encoder.videoUrl("url") == alternative, "Selected alternative line must survive playback encoding")
        guard let scheme = encoder.iinaDefaultUrl("url"), let components = URLComponents(string: scheme),
              let encodedMedia = components.queryItems?.first(where: { $0.name == "url" })?.value else {
            throw Failure(message: "Missing IINA URL")
        }
        try require(encodedMedia == alternative, "IINA query encoding must preserve signed URL delimiters")
        func pluginQuery(_ value: PlaybackEncoder) throws -> [String: String] {
            guard let scheme = value.iinaPluginUrl("url"),
                  let items = URLComponents(string: scheme)?.queryItems else {
                throw Failure(message: "Missing plugin launch URL")
            }
            return Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })
        }
        let firstLaunch = try pluginQuery(encoder)
        var nextEpisode = YouGetJSON(url: "https://media.invalid/episode-2.mp4")
        nextEpisode.site = media.site
        nextEpisode.title = media.title
        let nextLaunch = try pluginQuery(PlaybackEncoder(media: nextEpisode, context: context))
        try require(firstLaunch["url"] != nextLaunch["url"],
                    "Different media must not share the proxy watch-later identity, even with identical titles")
        let repeatedLaunch = try pluginQuery(encoder)
        try require(firstLaunch["url"] == repeatedLaunch["url"],
                    "Encoding the same prepared media must retain its playback identity")
        try require(firstLaunch["mpv_start"] == "0" && nextLaunch["mpv_start"] == "0",
                    "A fresh plugin launch must start at zero rather than inherit the previous media position")
        var resumeContext = context
        resumeContext.playerOptions = ["start=127.25", "resume-playback=no", "input-ipc-server=/tmp/private-player-ipc"]
        let resumed = PlaybackEncoder(media: media, context: resumeContext)
        let resumeLaunch = try pluginQuery(resumed)
        try require(resumeLaunch["mpv_start"] == "127.25" && resumeLaunch["mpv_input-ipc-server"] == "/tmp/private-player-ipc", "Plugin URL scheme must preserve fractional resume and isolated IPC")
        for scheme in [resumed.iinaDefaultUrl("url"), resumed.iinaPluginUrl("url")] {
            let items = URLComponents(string: scheme ?? "")?.queryItems ?? []
            try require(items.contains { $0.name == "new_window" && $0.value == "1" }, "Each resume must own a separate player window")
            try require(items.contains { $0.name == "mpv_resume-playback" && $0.value == "no" }, "Player watch-later state must never override selected progress")
        }
        try require(resumed.mpvOptions.contains("start=127.25"), "CLI options must preserve resume position")
        let payload = try pluginPayload(encoder, key: "url")
        try require(payload["currentLine"] as? Int == 1 && payload["currentQuality"] as? Int == 0,
                    "Plugin quality and alternative-line selection must match media selection")
        try require(payload["urls"] as? [String] == ["https://media.invalid/primary.mp4", alternative],
                    "Plugin URL order must keep primary then alternatives")
        try require(payload["port"] as? Int == endpoint.port && payload["type"] as? Int == PluginOptionsType.ws.rawValue,
                    "Plugin must receive the prepared endpoint and live danmaku mode")

        let xml = PlaybackEncoder(media: media, context: PlaybackEncodingContext(endpoint: endpoint, enableDanmaku: true, danmakuFile: "/tmp/prepared.xml"))
        let xmlPayload = try pluginPayload(xml, key: "url")
        try require(xmlPayload["type"] as? Int == PluginOptionsType.xmlFile.rawValue && xmlPayload["xmlPath"] as? String == "/tmp/prepared.xml",
                    "Prepared XML must override live danmaku mode without filesystem lookup in encoder")

        let direct = PlaybackEncoder(media: media, context: PlaybackEncodingContext(endpoint: nil, enableDanmaku: false, danmakuFile: nil))
        try require(direct.iinaPluginUrl("url") == nil && direct.danmakuUrl("url") == nil,
                    "Local-service URLs must not be manufactured without a ready endpoint")
        try require(direct.videoUrl("url") == alternative, "Direct mpv media must remain available without a local service")
        media.selection?.lineID = "2"
        let invalid = PlaybackEncoder(media: media, context: context)
        try require(invalid.videoUrl("url") == nil, "An invalid selected line must not silently choose the primary")
        print("Playback encoding regressions passed: signed URLs, selection, XML precedence, endpoint requirement")
    }
}
