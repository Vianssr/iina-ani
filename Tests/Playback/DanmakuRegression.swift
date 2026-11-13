import Foundation
import SwiftProtobuf
@testable import IINA_ANI

@main
@MainActor
enum DanmakuRegression {
    private struct Failure: Error { let message: String }
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.withLock { value += 1 } }
        var count: Int { lock.withLock { value } }
    }

    @MainActor
    private final class Recorder: DanmakuWSDelegate {
        var events: [[String: Any]] = []
        func writeDanmakuEventText(contextName: String, _ string: String) {
            if let data = string.data(using: .utf8),
               let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                events.append(event)
            }
        }
    }

    static func main() throws {
        try preferences()
        try liveMetadata()
        try protocolCompatibility()
        print("PASS: persisted danmaku snapshots, change notifications, live metadata, legacy protocol isolation")
    }

    private static func preferences() throws {
        let suite = "iina-danmaku-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let counter = Counter()
        let observer = NotificationCenter.default.addObserver(
            forName: Preferences.danmakuSettingsDidChangeNotification,
            object: preferences, queue: nil) { _ in counter.increment() }
        defer { NotificationCenter.default.removeObserver(observer) }
        let original = preferences.danmakuSettings
        preferences.danmukuFontFamilyName = "Noto Sans ' CJK"
        preferences.danmukuFontWeight = "Bold"
        preferences.danmukuFontSize = 37
        preferences.dmSpeed = 1234
        preferences.dmOpacity = 0.42
        preferences.dmUseSourceColor = false
        preferences.dmBlockType = ["Top", "Color"]
        preferences.dmHoverPause = false
        try require(counter.count == 8, "each changed setting emits exactly one dedicated notification")
        let snapshot = preferences.danmakuSettings
        preferences.danmukuFontFamilyName = snapshot.fontFamily
        preferences.danmukuFontWeight = snapshot.fontWeight
        preferences.danmukuFontSize = snapshot.fontSize
        preferences.dmSpeed = snapshot.speed
        preferences.dmOpacity = snapshot.opacity
        preferences.dmUseSourceColor = snapshot.useSourceColor
        preferences.dmBlockType = snapshot.blockTypes
        preferences.dmHoverPause = snapshot.hoverPause
        try require(counter.count == 8, "writing unchanged settings emits no duplicate notifications")
        let reopened = Preferences(defaults: UserDefaults(suiteName: suite)!)
        try require(reopened.danmakuSettings == snapshot && reopened.danmukuFontSize == 37,
                    "the complete snapshot, including custom size, survives a fresh Preferences instance")
        try require(original.fontSize == 24 && original.speed == 680 && original.opacity == 1 &&
                    original.useSourceColor && original.hoverPause,
                    "captured defaults remain immutable after preference changes")
        let data = try JSONEncoder().encode(snapshot)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try require(object["fontFamily"] as? String == snapshot.fontFamily &&
                    object["fontWeight"] as? String == snapshot.fontWeight &&
                    object["fontSize"] as? Int == 37 && object["speed"] as? Double == 1234 &&
                    object["opacity"] as? Double == 0.42 && object["useSourceColor"] as? Bool == false &&
                    object["blockTypes"] as? [String] == ["Top", "Color"] && object["hoverPause"] as? Bool == false,
                    "the encoded settings snapshot preserves all independently edited values")
        preferences.danmukuFontSize = -10
        preferences.dmSpeed = .infinity
        preferences.dmOpacity = 4
        try require(preferences.danmukuFontSize == 12 && preferences.dmSpeed == 680 && preferences.dmOpacity == 1,
                    "invalid preference inputs are bounded before persistence")
        let changed = counter.count
        preferences.danmukuFontSize = 0
        preferences.dmSpeed = .nan
        preferences.dmOpacity = 10
        try require(counter.count == changed, "equivalent clamped values must not create new settings broadcasts")
        try require(Preferences(defaults: UserDefaults(suiteName: suite)!).danmakuSettings == preferences.danmakuSettings,
                    "clamped settings, not invalid input values, are persisted")
    }

    private static func liveMetadata() throws {
        let danmaku = Danmaku("https://live.bilibili.com/1", decoder: VideoDecoder())
        for mode in [4, 5] {
            let json: [String: Any] = ["cmd": "DANMU_MSG", "info": [[0, mode, 36, 0], "black fixed"]]
            let decoded = danmaku.decodeBiliLiveDM(try JSONSerialization.data(withJSONObject: json))
            try require(decoded?.text == "black fixed" && decoded?.color == 0 &&
                        decoded?.mode == mode && decoded?.fontSize == 36,
                        "short legacy Bili payloads preserve black and both fixed modes")
            var proto = BilibiliDm_Community_Service_Dm_Live_Dm()
            proto.text = "protobuf fixed"
            proto.mode = Int32(mode)
            proto.size = 30
            proto.color = 0
            let payload = try JSONSerialization.data(withJSONObject: ["dm_v2": try proto.serializedData().base64EncodedString()])
            let decodedProto = danmaku.decodeBiliLiveDM(payload)
            try require(decodedProto?.text == proto.text && decodedProto?.color == 0 &&
                        decodedProto?.mode == mode && decodedProto?.fontSize == 30,
                        "protobuf black (including its omitted scalar default) is not mistaken for missing color")
        }
        let invalid: [String: Any] = ["cmd": "DANMU_MSG", "info": [[0, -1, 0, 0x1000000], "plain"]]
        let decoded = danmaku.decodeBiliLiveDM(try JSONSerialization.data(withJSONObject: invalid))
        try require(decoded?.text == "plain" && decoded?.color == nil && decoded?.mode == nil && decoded?.fontSize == nil,
                    "invalid RGB, negative mode, and zero size do not become render metadata")
        let truncated: [[Any]] = [[], [[0, 1, 25, 0]], [[0], "short"]]
        for info in truncated {
            let data = try JSONSerialization.data(withJSONObject: ["cmd": "DANMU_MSG", "info": info])
            try require(danmaku.decodeBiliLiveDM(data) == nil, "truncated metadata must return nil rather than index outside the payload")
        }
        let plain = DanmakuComment(text: "source without metadata")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as! [String: Any]
        try require(encoded["color"] == nil && encoded["mode"] == nil && encoded["fontSize"] == nil,
                    "plain sources must not synthesize color, placement, or size")
    }

    private static func protocolCompatibility() throws {
        for version in [0, 1, 2] {
            let recorder = Recorder()
            var connection = DanmakuWS(id: "test", site: .local, url: "", contextName: "test")
            connection.version = version
            connection.delegate = recorder
            connection.synchronizeSettings()
            if version == 2 {
                try require(recorder.events.count == 1 && recorder.events[0]["method"] as? String == "dmSettings",
                            "modern consumers receive one atomic settings event")
                let text = recorder.events[0]["text"] as! String
                let actual = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! NSDictionary
                let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences.shared.danmakuSettings)) as! NSDictionary
                try require(actual == expected, "the modern event contains the complete current preferences snapshot")
            } else {
                try require(!recorder.events.isEmpty && !recorder.events.contains { $0["method"] as? String == "dmSettings" },
                            "legacy integrations retain only their supported individual settings events")
                let before = recorder.events.count
                connection.send(.init(method: .dmSettings, text: "{}"))
                try require(recorder.events.count == before, "even direct modern event sends are isolated from old integrations")
            }
            recorder.events.removeAll()
            connection.send(.init(method: .sendDM, text: "", dms: [DanmakuComment(text: "first", color: 0, mode: 4, fontSize: 32), DanmakuComment(text: "second")]))
            if version == 0 {
                try require(recorder.events.compactMap { $0["text"] as? String } == ["first", "second"],
                            "v0 comments retain their original per-message text protocol")
            } else {
                let comments = recorder.events.first?["dms"] as? [[String: Any]]
                try require(comments?.count == 2 && comments?.first?["color"] as? Int == 0 &&
                            comments?.first?["mode"] as? Int == 4 && comments?.first?["fontSize"] as? Int == 32,
                            "batched consumers retain source metadata in the encoded event")
            }
        }
    }
}
