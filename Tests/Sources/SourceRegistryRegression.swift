import Foundation
import Cocoa
@testable import IINA_ANI

@main enum SourceRegistryRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }

    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let builtin = root.appendingPathComponent("IINA-ANI/Sources", isDirectory: true)
        let fixture = root.appendingPathComponent("Tests/Fixtures/Sources/internet-archive.json")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iina-w3-registry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let registry = SourceRegistry.shared
        try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
        let videoItem = try registry.item(for: "https://www.bilibili.com/video/BV1xx411c7mD")
        let pgcItem = try registry.item(for: "https://www.bilibili.com/bangumi/play/ep282958")
        let liveItem = try registry.item(for: "https://live.bilibili.com/1010")
        try require(registry.classification(for: videoItem).kind == .video && registry.classification(for: liveItem).kind == .live,
                    "mixed Bili content must use concrete adapter routes")
        try require(registry.classification(for: pgcItem).kind == .unknown &&
                    registry.classification(for: pgcItem).provenance == "bilibili.pgc.awaiting-bangumi-lookup",
                    "PGC path alone must not fabricate anime before Bangumi title lookup")
        let fqdmItem = try registry.item(for: "https://www.fqdm.cc/index.php/vod/detail/id/7.html")
        try require(registry.classification(for: fqdmItem).kind == .anime && registry.classification(for: fqdmItem).provenance.hasPrefix("source-schema:"), "pure animation configuration needs explicit schema evidence")
        for raw in ["https://jibi.cc/index.php/vod/detail/id/7.html", "https://www.jibi.cc/index.php/vod/play/id/7/sid/1/nid/1.html",
                    "https://dilidili.io/anime/example/", "https://www.dilidili.io/watch/example/"] {
            let item = try registry.item(for: raw)
            try require(registry.classification(for: item).kind == .anime &&
                        registry.classification(for: item).provenance.hasPrefix("native-adapter:"),
                        "Jibi and Dilidili must declare animation for detail and episode routes")
        }
        for sourceID in ["didahd", "kanba", "youknow", "rebo"] {
            let item = SourceItemRef(sourceID: sourceID, pageURL: "https://example.invalid/detail/7", kind: .work)
            try require(registry.classification(for: item).kind == .unknown,
                        "mixed source or work-shaped URL alone must remain unknown")
        }
        let hanimeItem = try registry.item(for: "https://hanime1.me/watch?v=408446")
        try require(hanimeItem.sourceID == "hanime1" && hanimeItem.kind == .video &&
                    registry.classification(for: hanimeItem).kind == .unknown,
                    "Hanime1 mixes animation and ordinary videos; a watch route must not imply anime")
        let forestURL = "https://www.hc34567.com/hcvoddetail/7.html"
        try require(registry.source(for: "forest") == nil && registry.descriptor(for: "forest") == nil &&
                    registry.matchingSite(forestURL) == .unsupported, "Forest must not remain a built-in source")
        let savedForestItem = SourceItemRef(sourceID: "forest", pageURL: forestURL, kind: .work)
        let preservedForestItem = try JSONDecoder().decode(SourceItemRef.self, from: JSONEncoder().encode(savedForestItem))
        try require(preservedForestItem == savedForestItem && registry.classification(for: preservedForestItem).kind == .unknown,
                    "removed sources must retain stored favorite identities without migration or deletion")
        let unavailableForestItem = try registry.favoriteItem(for: forestURL)
        try require(unavailableForestItem.pageURL == forestURL && unavailableForestItem.sourceID == "unavailable",
                    "removed Forest links must remain accessible through the unavailable favorite fallback")
        let classificationDecoder = VideoDecoder(registry: registry)
        var fakeVideo = PlayableSelection(item: fqdmItem, qualityID: "url", classification: MediaClassification(kind: .live, provenance: "manual"))
        fakeVideo.item = SourceItemRef(sourceID: fqdmItem.sourceID, pageURL: fqdmItem.pageURL, kind: .video)
        do {
            try DownloadSourceResolver(decoder: classificationDecoder).validate(fakeVideo)
            throw Failure.assertion("live content with a video-shaped ref was accepted for download")
        } catch DownloadFailure.unsupportedMedia { }

        let page = "https://archive.org/details/BigBuckBunny_328?file=BigBuckBunny_512kb.mp4"
        try require(registry.matching(url: page) == nil, "unloaded user configurations must not recognize URLs")
        let user = temporary.appendingPathComponent("user.json")
        let original = try Data(contentsOf: fixture)
        try original.write(to: user)
        try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
        guard let source = registry.matching(url: page) else { throw Failure.assertion("reloaded user source is unavailable") }
        let ref = try source.item(page)
        try require(ref.sourceID == "internet-archive" && ref.pageURL == page && ref.kind == .episode,
                    "file selection must retain durable query identity and source ID")
        try require(registry.classification(for: ref) == .unknown, "external source without contentKind must stay unknown despite title or catalog")
        let other = try source.item("https://archive.org/details/BigBuckBunny_328?file=other.mp4")
        try require(other != ref, "different files must not collapse to one source episode")
        try require(registry.matching(url: "https://archive.org.attacker.invalid/details/BigBuckBunny_328") == nil,
                    "host suffixes must not impersonate a configured source")

        let movie = "https://senfun.in/vodwatch/2025261963/hd.html"
        let moviePage = SupportSites.senfunPage(URLComponents(string: movie)!)
        try require(moviePage?.id == 2025261963 && moviePage?.episode == "hd",
                    "movie slugs must retain their title and selection identity")
        try require(registry.matchingSite(movie) == .senfun, "movie playback links must be selectable")
        try require(SupportSites.senfunPage(URLComponents(string: "https://senfun.in/vodwatch/2025261963/ep1_02.html")!)?.episode == "ep1_02",
                    "episode suffixes must remain distinct selections")
        for path in ["/vodwatch/2025261963/.html", "/vodwatch/2025261963/hd%2Fep1.html", "/vodwatch/2025261963/../hd.html"] {
            try require(SupportSites.senfunPage(URLComponents(string: "https://senfun.in" + path)!) == nil,
                        "invalid or traversal slugs must not enter the catalog")
        }
        let sakura = "https://www.yinghuabb.com/index.php/vod/detail/id/79473.html"
        try require(registry.matchingSite(sakura) == .yinghua, "the new Sakura domain must resolve saved links")
        try require(NSPredicate(format: SupportSites.yinghua.urlFilterPredicate).evaluate(with: ["url": sakura]),
                    "Sakura bookmarks must include the new domain")
        try require(registry.matchingSite("https://www.yinghuabb.com.attacker.invalid/index.php/vod/detail/id/79473.html") == .unsupported,
                    "the new Sakura domain must not admit lookalike hosts")
        let eacg = "https://www.eacg1.com/Comicplay/69000-3-2.html"
        let eacgPage = SupportSites.eacgPage(URLComponents(string: eacg)!)
        try require(eacgPage?.id == 69000 && eacgPage?.line == 3 && eacgPage?.episode == 2,
                    "current EACG routes must retain their server line and episode identities")
        try require(registry.matchingSite("https://www.eacg1.com/voddetails-69000.html") == .eacg,
                    "current EACG detail routes must be selectable")
        try require(NSPredicate(format: SupportSites.eacg.urlFilterPredicate).evaluate(with: ["url": eacg]),
                    "current EACG playback bookmarks must retain their source")
        let rebo = "https://www.rebozj.cc/play/3832-4-1.html"
        let reboPage = SupportSites.reboPage(URLComponents(string: rebo)!)
        try require(reboPage?.id == 3832 && reboPage?.line == 4 && reboPage?.episode == 1,
                    "Rebo routes must retain playlist identity independently of tab order")
        try require(registry.matchingSite(rebo) == .rebo, "Rebo playback links must have a stable native source")
        try require(NSPredicate(format: SupportSites.rebo.urlFilterPredicate).evaluate(with: ["url": rebo]),
                    "Rebo bookmarks must retain their source")
        try require(registry.matchingSite("https://www.rebozj.cc.attacker.invalid/play/3832-4-1.html") == .unsupported,
                    "Rebo classification must reject lookalike hosts")

        let magnet = "magnet:?xt=urn:btih:" + String(repeating: "a", count: 40)
        let magnetInput = try registry.torrentInput(for: magnet)
        let torrentItem = try registry.item(for: magnet)
        try require(magnetInput?.scheme == "magnet" && torrentItem.sourceID == "torrent" && torrentItem.kind == .work,
                    "magnet enters metadata import, not an automatically selected media file")
        let localTorrent = try registry.item(for: "file:///tmp/example.torrent")
        let localVideo = try registry.item(for: "file:///tmp/example.mkv")
        try require(localTorrent.sourceID == "torrent" && localVideo.sourceID == "local",
                    "local torrent metadata must not enter the local media decoder")
        for raw in ["magnet://attacker/?xt=urn:btih:abc", "magnet:?dn=no-hash", "file://remote/share/example.torrent"] {
            do {
                _ = try registry.torrentInput(for: raw)
                throw Failure.assertion("invalid torrent input was accepted")
            } catch VideoGetError.invalidLink {}
        }
        var torrentConflict = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        torrentConflict["id"] = "torrent"
        try JSONSerialization.data(withJSONObject: torrentConflict).write(to: user)
        do {
            try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
            throw Failure.assertion("user configuration hijacked native torrent identity")
        } catch SourceRegistry.RegistryError.duplicateID {}

        var conflict = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        conflict["id"] = "fqdm"
        try JSONSerialization.data(withJSONObject: conflict).write(to: user)
        do {
            try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
            throw Failure.assertion("user sources must not replace built-in source identities")
        } catch SourceRegistry.RegistryError.duplicateID {}
        try require(registry.matching(url: page)?.id == "internet-archive", "failed reload must retain the last working snapshot")

        conflict = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        conflict["hosts"] = ["archive.org", "www.bilibili.com"]
        try JSONSerialization.data(withJSONObject: conflict).write(to: user)
        do {
            try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
            throw Failure.assertion("configured hosts must not hijack native adapters")
        } catch SourceRegistry.RegistryError.hostConflict {}
        try require(registry.matching(url: page)?.id == "internet-archive", "host conflict must not discard the prior snapshot")
        let coldRegistry = SourceRegistry(builtinDirectory: builtin, userDirectory: temporary)
        try require(coldRegistry.matchingSite("https://www.fqdm.cc/index.php/vod/play/id/12/sid/1/nid/2.html").sourceID == "fqdm",
                    "a rejected user config at startup must not remove built-in source identities")
        try require(coldRegistry.matchingSite("https://www.bilibili.com/video/BV1xx411c7mD") == .bilibili,
                    "a rejected user config at startup must not remove native source identities")

        conflict = try JSONSerialization.jsonObject(with: original) as! [String: Any]
        conflict["version"] = 999
        try JSONSerialization.data(withJSONObject: conflict).write(to: user)
        do {
            try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
            throw Failure.assertion("unsupported schema version must be refused")
        } catch is Failure { throw Failure.assertion("unsupported schema version was accepted") }
        catch {}
        try require(registry.matching(url: page)?.id == "internet-archive", "invalid config must preserve working sources")

        try original.write(to: user)
        try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
        let decoder = VideoDecoder(registry: registry, sourceEnabled: { Preferences.shared.isSourceEnabled($0) })
        let localFile = temporary.appendingPathComponent("local-media.mp4")
        try Data().write(to: localFile)
        let localChoice = try await decoder.selection(for: localFile.absoluteString)
        try require(localChoice.item.sourceID == "local" && localChoice.item.kind == .local,
                    "local URLs must use source-owned local identity")
        let localCatalog = try await decoder.catalog(for: localChoice)
        try require(localCatalog == nil, "local sources do not expose an episode catalog")
        guard case .playable = try await decoder.inspect(localChoice) else {
            throw Failure.assertion("inspect(file URL) must return a playable local selection")
        }
        let enabled = Preferences.shared.isSourceEnabled("internet-archive")
        defer { Preferences.shared.setSourceEnabled(enabled, sourceID: "internet-archive") }
        Preferences.shared.setSourceEnabled(false, sourceID: "internet-archive")
        try require(registry.matchingSite(page).sourceID == ref.sourceID,
                    "disabling operations must not erase the source identity of existing bookmarks")
        do {
            _ = try await decoder.selection(for: page)
            throw Failure.assertion("disabled source must reject a new selection before I/O")
        } catch SiteAccountError.disabled {}
        Preferences.shared.setSourceEnabled(true, sourceID: "internet-archive")
        let choice = try await decoder.selection(for: page)
        try require(choice.item == ref, "registry selection must preserve configured episode identity")

        try FileManager.default.removeItem(at: user)
        try registry.reload(builtinDirectory: builtin, userDirectory: temporary)
        do {
            _ = try await decoder.selection(for: page)
            throw Failure.assertion("a removed user source must not survive through a cached adapter")
        } catch VideoGetError.notSupported {}
        print("PASS: runtime-only sources, durable file identity, reload conflicts, retained snapshots, source disablement and removal")
    }
}
