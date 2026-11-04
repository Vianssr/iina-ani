import SourceCore
import Foundation

@MainActor enum CSS1ProtocolRegression {
    static func run() async throws {
        let xifan = try source("dm1.xfdm.pro")
        precondition(tryURL(xifan, "https://play.xfvod.pro:8088/video.mp4", media: true))
        for address in ["http://play.xfvod.pro:8088/video.mp4", "https://play.xfvod.pro:8089/video.mp4",
                        "https://evil.example:8088/video.mp4", "https://play.xfvod.pro.evil.example:8088/video.mp4",
                        "https://user:secret@play.xfvod.pro:8088/video.mp4"] {
            precondition(!tryURL(xifan, address, media: true))
        }
        precondition(!tryURL(xifan, "https://play.xfvod.pro:8088/video.mp4", media: false))
        let unrelated = try source("unrelated.example")
        precondition(!tryURL(unrelated, "https://play.xfvod.pro:8088/video.mp4", media: true))
        for (old, current) in [("www.2kdm.com", "www.mutedm.com"), ("www.didahd.pro", "www.didahd.xyz"), ("www.rebozj.pro", "www.rebozj.cc")] {
            let config = try source(old)
            precondition(config.requestHosts == Set([old, current]))
            precondition(tryURL(config, "https://\(current)/play/1-1-1.html", media: false))
            precondition(!tryURL(config, "https://\(current).evil.example/play/1-1-1.html", media: false))
            precondition(!tryURL(config, "http://\(current)/play/1-1-1.html", media: false))
            let original = "https://\(old)/play/1-1-1.html"
            let item = try config.webItem(original, kind: .episode)
            precondition(item.pageURL == original)
        }
        let cipher = "Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M="
        let plain = try PublicPlayerProtocol.decrypt(cipher, timestamp: "1700000000")
        precondition(plain == "https://media.example/video.mp4") // Independent Node/OpenSSL AES fixture.
        for (data, time) in [("not base64", "1700000000"), (cipher, "1700000001")] {
            do { _ = try PublicPlayerProtocol.decrypt(data, timestamp: time); fatalError("Invalid ciphertext accepted") }
            catch { precondition(MobileSourceClient.failure(for: error) == .invalidPlayerData) }
        }
        let dida = try source("www.didahd.pro")
        let page = URL(string: "https://www.didahd.pro/play/42-2-3.html")!
        let payload: [String: Any] = ["url": "aabb", "from": "BBA", "id": "42", "sid": 2, "nid": 3]
        for smart in [false, true] {
            let client = PublicPlayerProtocol(configuration: dida) { request in
                let url = request.url!
                precondition(PublicPlayerProtocol.permits(request, configuration: dida))
                precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
                if url.path == "/static/player/BBA.js" { return Data("src='/static/player/artplayer/?url='+MacPlayer.PlayUrl".utf8) }
                if url.path == "/static/player/artplayer" {
                    precondition(request.value(forHTTPHeaderField: "Referer") == "https://www.didahd.xyz/play/42-2-3.html")
                    return Data("const timestamp=\"1700000000\";const isSmartPlay=\(smart);const playPageUrl=\"fixture-key\";const secretKeySeed=\"fixture-code\";const qualities=[{\"url\":\"\(cipher)\"}];".utf8)
                }
                precondition(url == PublicPlayerProtocol.smartAPI && request.httpMethod == "POST")
                let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                precondition(body["vkey"] as? String == "fixture-key" && body["code"] as? String == "fixture-code")
                let time = body["t"] as! Int
                precondition(body["signature"] as? String == PublicPlayerProtocol.md5(String(time)))
                return try JSONSerialization.data(withJSONObject: ["code": 200, "url": cipher])
            }
            let result = try await client.resolve(payload, page: page)
            precondition(result.absoluteString == plain)
        }
        let signed = "qeNtD9QLONbqjqdA86TB9Z6fwGCooeB2pxVJtZt6gmYzR+SEKnV3IPiOjvELolA2Se7EOxL3eTCqqn7X3DGclw=="
        for candidate in [signed, "https://ykj-eos-dg5-01.eos-dongguan-6.cmecloud.cn/video"] {
            for validMP4 in [true, false] {
                let client = PublicPlayerProtocol(configuration: dida) { request in
                    if request.url!.path.hasSuffix(".js") { return Data("/static/player/artplayer/?url=".utf8) }
                    if request.url!.host == "www.didahd.xyz" {
                        return Data("const timestamp=\"1700000000\";const isSmartPlay=false;const qualities=[{\"url\":\"\(candidate)\"}];".utf8)
                    }
                    precondition(request.value(forHTTPHeaderField: "Range") == "bytes=0-63")
                    return validMP4 ? Data([0, 0, 0, 24] + Array("ftypisom".utf8)) : Data("<html>Denied</html>".utf8)
                }
                do { let result = try await client.resolve(payload, page: page); precondition(validMP4 && ["image", ""].contains(result.pathExtension)) }
                catch { precondition(!validMP4 && MobileSourceClient.failure(for: error) == .unsupportedMediaFormat) }
            }
        }
        let forbidden = PublicPlayerProtocol(configuration: dida) { _ in fatalError("Invalid episode made a request") }
        do { _ = try await forbidden.resolve(payload, page: URL(string: "https://www.didahd.pro/play/42-2-4.html")!); fatalError("Wrong episode accepted") }
        catch { precondition(MobileSourceClient.failure(for: error) == .missingEpisode) }
        for url in ["https://evil.example/static/player/artplayer/", "https://hd.ticktockwow.com/other", "http://www.didahd.xyz/static/player/BBA.js", "https://www.didahd.xyz:443/static/player/BBA.js"] {
            precondition(!PublicPlayerProtocol.permits(URLRequest(url: URL(string: url)!), configuration: dida))
        }
        let mutedm = try source("www.2kdm.com")
        for correctToken in [true, false] {
            let client = PublicPlayerProtocol(configuration: mutedm) { request in
                if request.url!.path.hasSuffix("index.php") {
                    let target = "/addons/dp/player/dp.php?id=42&from=m2&url=\(correctToken ? "test-token" : "wrong-token")"
                    let literal = String(decoding: try JSONEncoder().encode(target), as: UTF8.self)
                    return Data("<script>window.location.href=\(literal);</script>".utf8)
                }
                precondition(correctToken)
                return Data("var config = {\"api\": '/', \"url\": \"https://media.example/video.mp4\", \"ads\":{\"label\":\"nested } brace\"}, \"api_vod_url\":\"test-token\"};".utf8)
            }
            do {
                let result = try await client.resolve(["id":"42", "sid":2, "nid":3, "from":"m2", "url":"test-token"], page: URL(string: "https://www.2kdm.com/vodplay/42-2-3.html")!)
                precondition(correctToken && result.absoluteString == plain)
            } catch { precondition(!correctToken && MobileSourceClient.failure(for: error) == .invalidPlayerData) }
        }
        for available in [true, false] {
            let client = PublicPlayerProtocol(configuration: xifan) { request in
                if request.url!.host == "dm1.xfdm.pro" {
                    return Data(#"MacPlayerConfig.player_list={"xfy2":{"parse":"https://player.moedot.net/player/index.php?code=xfdm1&from=cf&url="}};"#.utf8)
                }
                precondition(request.url!.path == "/player/ec.php")
                let body: [String: Any] = ["code": available ? 200 : 101, "type":"auto", "config":["uid":"ABC123"],
                    "url":"2vU0R7YdSTx+5ZL11RWobGoXKQg6LcYDITFDgFE5hAE="]
                return Data(("var ConFig=" + String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self) + ",box={};").utf8)
            }
            do {
                let result = try await client.resolveXiFan(["id":"42", "sid":1, "nid":2, "from":"xfy2", "url":"https://play.xfvod.pro:8088/video.mp4"], page: URL(string:"https://dm1.xfdm.pro/watch/42/1/2.html")!)
                precondition(available && result.absoluteString == plain)
            } catch { precondition(!available && MobileSourceClient.failure(for: error) == .playerServiceUnavailable) }
        }
        print("PASS: exact media port and site moves, preserved identity, AES vectors, public player/API binding, signed MP4 sniffing and rejected endpoints")
    }

    private static func source(_ host: String) throws -> SourceConfiguration {
        let item: [String: Any] = ["id": "protocol-fixture", "version": 2, "factoryId": "web-selector",
            "arguments": ["name": "Protocol fixture", "searchConfig": ["searchUrl": "https://\(host)/search?q={keyword}",
                "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists":"a.result"],
                "channelFormatId":"no-channel", "selectorChannelFormatNoChannel":["selectEpisodes":"a.episode"]]]]
        return try MobileCSS1Configuration.convert(data: JSONSerialization.data(withJSONObject: ["mediaSources":[item]])).drafts[0].configuration
    }
    private static func tryURL(_ config: SourceConfiguration, _ raw: String, media: Bool) -> Bool {
        (try? config.requestURL(raw, media: media)) != nil
    }
}
