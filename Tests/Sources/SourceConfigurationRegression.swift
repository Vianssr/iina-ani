import Foundation
@testable import IINA_ANI

@main
enum SourceConfigurationRegression {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let fqdm = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let archive = try SourceConfiguration.load(fileURL: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))
        let archiveWork = try archive.item("https://archive.org/details/BigBuckBunny_328")
        let archiveEpisodeURL = "https://archive.org/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4"
        let archiveEpisode = try archive.item(archiveEpisodeURL)
        let archiveParts = try archive.parts(archiveEpisodeURL)
        try require(archiveWork.sourceID == "internet-archive" && archiveWork.kind == .work, "alphanumeric configured work identity")
        try require(archiveEpisode.sourceID == "internet-archive" && archiveEpisode.pageURL == archiveEpisodeURL && archiveEpisode.kind == .episode, "JSON entry name is durable episode identity")
        let archiveFragment = try archive.item("HTTPS://ARCHIVE.ORG/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4#notes")
        let archiveOtherFile = try archive.item("https://archive.org/details/BigBuckBunny_328?file=alternate.mp4")
        try require(archiveFragment.pageURL == archiveEpisodeURL && archiveOtherFile.pageURL != archiveEpisode.pageURL, "fragment stripping canonicalizes host while preserving episode query identity")
        var archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        var brokenCatalog = archiveJSON["catalog"] as! [String: Any]
        brokenCatalog.removeValue(forKey: "jsonEntriesPath")
        archiveJSON["catalog"] = brokenCatalog
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        brokenCatalog = archiveJSON["catalog"] as! [String: Any]
        brokenCatalog["jsonEntriesPath"] = "files"
        brokenCatalog.removeValue(forKey: "jsonEpisodeIdentityPath")
        brokenCatalog.removeValue(forKey: "jsonEpisodeURLPath")
        archiveJSON["catalog"] = brokenCatalog
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        brokenCatalog = archiveJSON["catalog"] as! [String: Any]
        brokenCatalog["url"] = "https://outside.example/metadata/{id}"
        archiveJSON["catalog"] = brokenCatalog
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        var brokenRoute = archiveJSON["route"] as! [String: Any]
        brokenRoute["pattern"] = "["
        archiveJSON["route"] = brokenRoute
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        archiveJSON["streamingDSL"] = "arbitrary"
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        archiveJSON["capabilities"] = ["information", "resolve", "episodes", "lines", "quality"]
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        try require(try archive.requestURL("https://archive.org/metadata/x?token=public-signature").absoluteString == "https://archive.org/metadata/x?token=public-signature", "public signed HTTPS requests remain usable")
        archiveJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json"))) as! [String: Any]
        var credentialCatalog = archiveJSON["catalog"] as! [String: Any]
        credentialCatalog["url"] = "https://archive.org/metadata/{id}?token=inline-secret"
        archiveJSON["catalog"] = credentialCatalog
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: archiveJSON)) as Any }
        try require(archiveParts.id == "BigBuckBunny_328" && archiveParts.episodeIdentity == "BigBuckBunny_512kb.mp4", "query identity survives canonical parsing")
        try rejects { try archive.item("https://archive.org/details/BigBuckBunny_328?file=") }
        try rejects { try archive.requestURL("http://archive.org/download/x/x.mp4", media: true) }
        try rejects { try archive.requestURL("https://user@archive.org/download/x/x.mp4", media: true) }
        let fqdmEpisode = try fqdm.item("https://www.fqdm.cc/index.php/vod/play/id/12/sid/3/nid/7.html")
        let zeroPadded = try fqdm.item("https://www.fqdm.cc/index.php/vod/play/id/0012/sid/3/nid/7.html")
        let zeroPaddedParts = try fqdm.parts(zeroPadded.pageURL)
        try require(zeroPadded.pageURL == "https://www.fqdm.cc/index.php/vod/play/id/0012/sid/3/nid/7.html" && zeroPaddedParts.id == "12", "CMS request identity normalizes numeric ID while retaining exact page identity")
        try require(fqdmEpisode.sourceID == "fqdm" && fqdmEpisode.pageURL == "https://www.fqdm.cc/index.php/vod/play/id/12/sid/3/nid/7.html", "page identity must be stable and exact")
        try require(fqdm.matches("http://fqdm.cc/index.php/vod/detail/id/12.html"), "configured detail pages match")
        try require(!fqdm.matches("https://fqdm.cc.evil.example/index.php/vod/detail/id/12.html"), "suffix host spoof must not match")
        try require(!fqdm.matches("https://user@fqdm.cc/index.php/vod/detail/id/12.html"), "userinfo URLs must not match")
        try require(!fqdm.matches("https://fqdm.cc:443/index.php/vod/detail/id/12.html"), "explicit ports must not match")
        try require(!fqdm.matches("https://www.fqdm.cc/index.php/vod/play/id/5/sid/0/nid/2.html"), "zero line identity must be rejected")
        try require(!fqdm.matches("https://www.fqdm.cc/index.php/vod/detail/id/0.html"), "zero catalog identity must be rejected")

        let player: [String: Any] = ["id": "12", "sid": 3, "nid": 7, "points": 0, "trysee": 0,
                                    "encrypt": 0, "url": "https://cdn.example/video.m3u8"]
        try require(try fqdm.validatedPlayerMediaURL(player, id: "12", line: 3, episode: 7) == "https://cdn.example/video.m3u8", "anonymous HTTPS CDN media is allowed")
        try require(try fqdm.validatedPlayerMediaURL(player.merging(["encrypt": 1, "url": "https%3A%2F%2Fcdn.example%2Fvideo.m3u8"]) { _, new in new }, id: "12", line: 3, episode: 7) == "https://cdn.example/video.m3u8", "percent-encoded player URLs decode safely")
        let base64URL = Data("https://cdn.example/video.m3u8".utf8).base64EncodedString()
        try require(try fqdm.validatedPlayerMediaURL(player.merging(["encrypt": 2, "url": base64URL]) { _, new in new }, id: "12", line: 3, episode: 7) == "https://cdn.example/video.m3u8", "base64 player URLs decode safely")
        try require(try fqdm.validatedPlayerMediaURL(player.merging(["url": "https://cdn.example/video.m3u8?token=public-signature"]) { _, new in new }, id: "12", line: 3, episode: 7) == "https://cdn.example/video.m3u8?token=public-signature", "signed public HTTPS media remains allowed without source credentials")
        try rejects { try fqdm.validatedPlayerMediaURL(player, id: "13", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["sid": 4]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["nid": 8]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["points": 1]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["trysee": 1]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["points": 0.5]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["trysee": 0.5]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["sid": 3.5]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["nid": 7.5]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["url": "file:///tmp/movie.mp4"]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["url": "https://user@cdn.example/movie.mp4"]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["url": "https://cdn.example/movie.mkv"]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["encrypt": 3]) { _, new in new }, id: "12", line: 3, episode: 7) }
        try rejects { try fqdm.validatedPlayerMediaURL(player.merging(["encrypt": 0.5]) { _, new in new }, id: "12", line: 3, episode: 7) }

        var fqdmJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))) as! [String: Any]
        _ = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: fqdmJSON))
        var accountJSON = fqdmJSON
        accountJSON["credentialHosts"] = ["fqdm.cc"]
        let accountConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: accountJSON))
        try rejects { try validateConfiguredSourceAccountContext(configuration: accountConfig, sourceID: "another-source") }
        try validateConfiguredSourceAccountContext(configuration: accountConfig, sourceID: "fqdm")
        try validateConfiguredSourceAccountContext(configuration: fqdm, sourceID: "another-source")
        fqdmJSON["cookie"] = "secret"
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: fqdmJSON)) as Any }
        fqdmJSON.removeValue(forKey: "cookie")
        fqdmJSON["token"] = "secret"
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: fqdmJSON)) as Any }
        fqdmJSON.removeValue(forKey: "token")
        var fqdmCatalog = fqdmJSON["catalog"] as! [String: Any]
        fqdmCatalog.removeValue(forKey: "episodeSelector")
        fqdmJSON["catalog"] = fqdmCatalog
        try rejects { try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: fqdmJSON)) as Any }
        print("PASS: configured source identities, URL constraints, player identity and media safety")
    }

    private static func rejects(_ operation: () throws -> Any) throws {
        do { _ = try operation(); throw Failure.assertion("unsafe input was accepted") }
        catch is Failure { throw Failure.assertion("unsafe input was accepted") }
        catch { return }
    }
    private static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure.assertion(message) }
    }
    private enum Failure: Error { case assertion(String) }
}
