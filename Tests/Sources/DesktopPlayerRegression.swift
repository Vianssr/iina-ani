import SourceCore
import Foundation
@testable import IINA_ANI

@main enum DesktopPlayerRegression {
    static func main() async throws {
        let decoded = try PublicPlayerProtocol.decrypt("Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M=", timestamp: "1700000000")
        precondition(decoded == "https://media.example/video.mp4")
        let failure = AnimeSourceService.diagnostic(PlaybackFailure.playerServiceUnavailable)
        precondition(!failure.isEmpty && failure != AnimeSourceService.diagnostic(PlaybackFailure.unsupportedEncryption))
        do {
            _ = try XiFan.resolvedMedia(#"var ConFig={"code":101},box={};"#)
            fatalError("Upstream failure accepted")
        } catch { precondition(error as? PlaybackFailure == .playerServiceUnavailable) }
        for code in [200, 103] {
            let html = "var ConFig={\"code\":\(code),\"type\":\"auto\",\"config\":{\"uid\":\"123456\"},\"url\":\"3j0GgaeIMy307OPFg0mZsvx/18tdSpXhr/6yFwegYgo=\"},box={};"
            let media = try XiFan.resolvedMedia(html)
            precondition(media == "https://media.example/video.mp4")
        }
        for (status, body, expected) in [(401, "expire missing", PlaybackFailure.mediaSignatureMissing),
                                         (401, "unauthorized", .authenticationRequired),
                                         (403, "forbidden", .httpForbidden), (404, "missing", .mediaNotFound)] {
            do {
                try XiFan.validateMediaResponse(status: status, prefix: Data(body.utf8))
                fatalError("Media rejection accepted")
            } catch { precondition(error as? PlaybackFailure == expected) }
        }
        try XiFan.validateMediaResponse(status: 206, prefix: Data())
        do {
            _ = try Mutedm.payload(#"var player_aaaa={"id":"42","sid":2,"nid":7,"points":0,"trysee":0,"encrypt":3,"from":"r2","url":"token"};"#, id:42,line:2,episode:7)
            fatalError("App-only line accepted")
        } catch { precondition(error as? PlaybackFailure == .appOnlyPlayback) }
        let nextDetail: [String: Any] = ["anime": ["id": 44, "title": "New catalog"], "sources": [
            ["id": 4, "code": "xfxf1", "name": "Main", "episodes": [["id": 501, "title": "Episode 7", "episode_number": 7]]]
        ]]
        let flight = "1:" + String(decoding: try JSONSerialization.data(withJSONObject: nextDetail), as: UTF8.self) + "\n"
        let cut = flight.index(flight.startIndex, offsetBy: flight.count / 2)
        var html = ""
        for part in [String(flight[..<cut]), String(flight[cut...])] {
            html += "<script>self.__next_f.push(" + String(decoding: try JSONSerialization.data(withJSONObject: [1, part]), as: UTF8.self) + ")</script>"
        }
        let nextCatalog = try XiFan.nextCatalog(html, id: 44)
        precondition(nextCatalog.lines[0].episodes[0].id == 501 && nextCatalog.lines[0].code == "xfxf1")
        let validNext = "https://next.xifanacg.com/anime/44/play/501?source=xfxf1"
        precondition(SupportSites.nativeSite(url: validNext) == .xiFan)
        for raw in ["https://next.xifanacg.com.evil.test/anime/44", "http://next.xifanacg.com/anime/44",
                    "https://next.xifanacg.com/anime/44/play/501?source=xfxf1&source=AL",
                    "https://next.xifanacg.com/anime/44/play/0", "https://next.xifanacg.com/watch/44/1/1.html"] {
            precondition(SupportSites.nativeSite(url: raw) == .unsupported)
        }
        for (anime, episode, source, accepted) in [(44, 501, 4, true), (45, 501, 4, false), (44, 502, 4, false), (44, 501, 1, false)] {
            let data = try JSONSerialization.data(withJSONObject: ["ok": true, "anime_id": 44, "episode_id": 501,
                "url": "https://media.example/episode.mp4?sign=fixture", "candidates": [["source_id": 4, "url": "https://media.example/episode.mp4?sign=fixture"]]])
            do { _ = try XiFan.nextMedia(data, anime: anime, episode: episode, source: source); precondition(accepted) }
            catch { precondition(!accepted && error as? PlaybackFailure == .missingEpisode) }
        }
        let oldMedia = URL(string: "https://play.xfvod.pro:8088/archive/episode.mp4?test=preserved")!
        precondition(XiFan.legacyHTTPSMedia(oldMedia)?.absoluteString == "https://play.xfvod.pro/archive/episode.mp4?test=preserved")
        for raw in ["https://play.xfvod.pro.evil.test:8088/episode.mp4", "http://play.xfvod.pro:8088/episode.mp4",
                    "https://play.xfvod.pro:8089/episode.mp4", "https://play.xfvod.pro:8088/episode.m3u8",
                    "https://user:pass@play.xfvod.pro:8088/episode.mp4", "https://other.example:8088/episode.mp4"] {
            precondition(XiFan.legacyHTTPSMedia(URL(string: raw)!) == nil)
        }
        for address in ["https://www.2kdm.com/vodplay/1932-3-1.html", "https://www.mutedm.com/voddetail/1932.html"] {
            precondition(SupportSites(url: address) == .mutedm)
        }
        for address in ["https://www.mutedm.com.evil.test/vodplay/1932-3-1.html", "https://www.mutedm.com/vodplay/1932-0-1.html", "https://user:password@www.mutedm.com/voddetail/1932.html"] {
            precondition(SupportSites(url: address) == .unsupported)
        }
        let catalog = try Mutedm.catalog(#"<h1>Fixture</h1><div class="module-tab-item" data-dropdown-value="Web"></div><div class="module-play-list-content"><a href="/vodplay/42-3-7.html">Episode 7</a></div>"#,id:42)
        precondition(catalog.nodes[0].children[0].url == "https://www.mutedm.com/vodplay/42-3-7.html")
        do {
            _ = try Mutedm.payload(#"var player_aaaa={"id":"42","sid":3,"nid":8,"points":0,"trysee":0,"encrypt":3,"from":"m2","url":"token"};"#,id:42,line:3,episode:7)
            fatalError("Mismatched episode accepted")
        } catch { precondition(error as? PlaybackFailure == .missingEpisode) }
        print("PASS desktop-linked AES, XiFan 200/103, media HTTP diagnostics, APP-only line and exact episode identity")
        guard CommandLine.arguments.contains("--live") else { return }
        let root = CommandLine.arguments[1]
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("mac-source-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let registry = SourceRegistry(builtinDirectory:URL(fileURLWithPath:root + "/IINA-ANI/Sources"),userDirectory:temporary)
        if let source = registry.builtinSearch(for:"mutedm") {
            do {
                let results = try await SourceSearchExecutor.search(query:"海贼王",page:1,spec:source.search,allowedHosts:Set(source.hosts),resultURLTemplate:source.resultURLTemplate,item:{ try? registry.item(for:$0) })
                print("2k native search results",results.results.count)
            } catch { print("2k search-failure",(error as NSError).code) }
        }
        for raw in ["https://dm1.xfdm.pro/watch/1086/1/1.html"] {
            do { _ = try await XiFan().decodeUrl(raw); print("XiFan parsed URL; playback not verified") }
            catch { print("XiFan resolve",(error as? PlaybackFailure)?.rawValue ?? "network-or-adapter",(error as NSError).code) }
        }
        for (name, decoder, page) in [
            ("dida", Didahd() as any SupportSiteProtocol, "https://www.didahd.xyz/detail/1164.html"),
            ("rebo", Rebo() as any SupportSiteProtocol, "https://www.rebozj.cc/detail/1164.html"),
            ("2k", Mutedm() as any SupportSiteProtocol, "https://www.mutedm.com/voddetail/1932.html")
        ] {
            do {
            let nodes: [VideoTreeNode]
            if let dida = decoder as? Didahd { nodes = try await dida.episodeList(page).nodes }
            else if let rebo = decoder as? Rebo { nodes = try await rebo.episodeList(page).nodes }
            else { nodes = try await (decoder as! Mutedm).episodeList(page).nodes }
            for node in nodes where node.title.contains("B") || node.title.contains("G") || (name == "2k" && node.title.contains("网页")) {
                guard let episode = node.children.first else { continue }
                do {
                let result = try await decoder.decodeUrl(episode.url)
                guard let media = result.streams.values.first?.url else { fatalError("No stream") }
                var request = URLRequest(url:URL(string:media)!)
                request.setValue("bytes=0-63", forHTTPHeaderField:"Range")
                let session = URLSession(configuration:.ephemeral)
                do {
                    let (bytes,response) = try await session.bytes(for:request)
                    var prefix = Data()
                    for try await byte in bytes { prefix.append(byte); if prefix.count == 16 { break } }
                    print(name, node.title, "media-status", (response as? HTTPURLResponse)?.statusCode ?? 0,
                          "host",response.url?.host ?? "", "prefix",prefix.map { String(format:"%02x",$0) }.joined())
                } catch { print(name, "probe-error",(error as NSError).code) }
                session.invalidateAndCancel()
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
                process.arguments = [root + "/.build/css1-diagnosis/verify.py", media,
                                     root + "/.build/mac-source-fix/" + name + "-" + String(episode.index) + "-frame.png"]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                print(name, node.title, episode.url, String(decoding: data, as: UTF8.self))
                } catch { print(name, node.title, "resolve-failure", (error as? PlaybackFailure)?.rawValue ?? "network-or-adapter", (error as NSError).code) }
            }
            } catch { print(name, "catalog-failure", (error as NSError).code) }
        }
    }
}
