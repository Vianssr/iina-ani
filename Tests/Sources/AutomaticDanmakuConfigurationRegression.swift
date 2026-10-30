import Foundation
@testable import IINA_ANI

@main
enum AutomaticDanmakuConfigurationRegression {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let file = root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json")
        let original = try SourceConfiguration.load(fileURL: file)
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        let page = "https://archive.org/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4"
        // Synthetic identity contract fixture only, not a claim that this archive
        // film corresponds to any Bilibili upload. Never ship this test binding.
        let binding: [String: Any] = ["pageURL": page, "aid": 7, "cid": 9]
        json["danmaku"] = ["provider": "bilibili-xml", "episodes": [binding]]
        try reject { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: json)) }
        json["version"] = 2
        let config = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: json))
        precondition(config.configurationRevision != original.configurationRevision)
        let work = try config.item("https://archive.org/details/BigBuckBunny_328")
        let episode = try config.item(page)
        let selection = PlayableSelection(item: work, episode: episode, lineID: "1", classification: config.classification)
        let match = try config.danmakuBinding(for: selection, revision: config.configurationRevision)
        precondition(match?.aid == 7 && match?.cid == 9 && match?.pageURL == page)
        let roundTrip = try SourceConfiguration.load(data: config.encodedData())
        precondition(roundTrip.configurationRevision == config.configurationRevision && roundTrip.danmaku?.episodes == config.danmaku?.episodes)
        var other = selection
        other.episode = try config.item("https://archive.org/details/BigBuckBunny_328?file=alternate.mp4")
        let missing = try config.danmakuBinding(for: other, revision: config.configurationRevision)
        precondition(missing == nil, "No title, catalogue-order or partial URL fallback")
        try reject { try config.danmakuBinding(for: selection, revision: original.configurationRevision) }
        other = selection
        other.item = try config.item("https://archive.org/details/another-work")
        try reject { try config.danmakuBinding(for: other, revision: config.configurationRevision) }
        other = selection
        other.episode = SourceItemRef(sourceID: "different-source", pageURL: page, kind: .episode)
        try reject { try config.danmakuBinding(for: other, revision: config.configurationRevision) }
        let invalidDeclarations: [[String: Any]] = [
            ["provider": "fqdm", "episodes": [binding]],
            ["provider": "bilibili-xml", "episodes": []],
            ["provider": "bilibili-xml", "episodes": [binding, binding]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page, "aid": 0, "cid": 9]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page, "aid": 7, "cid": true]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page, "aid": 7, "cid": 9.5]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page + "&token=secret", "aid": 7, "cid": 9]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page + "#fragment", "aid": 7, "cid": 9]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": "https://other.example/episode/1", "aid": 7, "cid": 9]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": work.pageURL, "aid": 7, "cid": 9]]],
            ["provider": "bilibili-xml", "episodes": [["pageURL": page, "aid": 7, "cid": 9, "cookie": "secret"]]],
            ["provider": "bilibili-xml", "episodes": [binding], "url": "https://other.example/comments"]
        ]
        for invalid in invalidDeclarations {
            var broken = json
            broken["danmaku"] = invalid
            try reject { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: broken)) }
        }
        var changed = json
        changed["danmaku"] = ["provider": "bilibili-xml", "episodes": [["pageURL": page, "aid": 7, "cid": 10]]]
        let replacement = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: changed))
        precondition(replacement.configurationRevision != config.configurationRevision)
        print("PASS: automatic danmaku declarations, exact episode/source/config identity, canonical URL and schema boundaries, lossless round-trip")
    }

    private static func reject<T>(_ operation: () throws -> T) throws {
        do { _ = try operation() }
        catch { return }
        preconditionFailure("Unsafe automatic danmaku configuration accepted")
    }
}
