import Foundation
import SourceCore
import XCTest
@testable import SourceRuntime

final class NativeComplexTests: XCTestCase {
    private enum FixtureError: Error { case unexpectedRequest(String) }

    private actor HTTPFixture {
        typealias Handler = @Sendable (URLRequest) throws -> SourceHTTPResponse
        let handler: Handler
        private var requests: [URLRequest] = []

        init(_ handler: @escaping Handler) { self.handler = handler }

        func fetch(_ request: URLRequest) throws -> SourceHTTPResponse {
            requests.append(request)
            return try handler(request)
        }

        func recorded() -> [URLRequest] { requests }
    }

    private static func response(_ request: URLRequest, _ body: String, status: Int = 200,
                                 headers: [String: String] = [:]) -> SourceHTTPResponse {
        SourceHTTPResponse(data: Data(body.utf8), url: request.url!, statusCode: status, headers: headers)
    }

    private static func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: .sortedKeys), as: UTF8.self)
    }

    private static func player(id: String = "42", line: Int, episode: Int, from: String,
                               url: String, encrypt: Int = 0, points: Int = 0,
                               preview: Int = 0) throws -> String {
        "<script>var player_aaaa=" + (try json([
            "id": id, "sid": line, "nid": episode, "from": from, "url": url,
            "encrypt": encrypt, "points": points, "trysee": preview
        ])) + ";</script>"
    }

    private func work(_ source: String, _ page: String) throws -> RuntimeWork {
        RuntimeWork(item: try RuntimeSource.native(source).item(page), title: "Untrusted search title")
    }

    private func failure(_ expected: PlaybackFailure, file: StaticString = #filePath, line: UInt = #line,
                         _ operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PlaybackFailure, expected, file: file, line: line)
        }
    }

    private func assertLeaves(_ catalog: RuntimeCatalog, source: String, title: String,
                              lines: [String], lineIDs: [Int], titles: [[String]], pages: [[String]],
                              numbers: [[Int]], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(catalog.work.title, title, file: file, line: line)
        XCTAssertEqual(catalog.work.item.sourceID, source, file: file, line: line)
        XCTAssertEqual(catalog.lines.map(\.title), lines, file: file, line: line)
        XCTAssertEqual(catalog.lines.map(\.id), lineIDs, file: file, line: line)
        XCTAssertEqual(catalog.lines.map { $0.episodes.map(\.title) }, titles, file: file, line: line)
        XCTAssertEqual(catalog.lines.map { $0.episodes.map { $0.item.pageURL } }, pages, file: file, line: line)
        XCTAssertEqual(catalog.lines.map { $0.episodes.map(\.number) }, numbers, file: file, line: line)
        for playbackLine in catalog.lines {
            for episode in playbackLine.episodes {
                XCTAssertEqual(episode.item.sourceID, source, file: file, line: line)
                XCTAssertEqual(episode.line, playbackLine.id, file: file, line: line)
            }
        }
    }

    private static let xiFanDetail = """
        <div class="detail-info"><h1 class="slide-info-title">XiFan fixture</h1></div>
        <div class="detail-pic"><img data-src="/cover.jpg"></div>
        <div class="anthology-tab"><div class="swiper-slide">Primary<span>2</span></div><div class="swiper-slide">Mirror</div></div>
        <div class="anthology-list">
          <div class="anthology-list-box">
            <a href="/watch/42/1/7.html">Episode seven</a><a href="/watch/42/1/9.html">Episode nine</a>
            <a href="/watch/43/1/7.html">Other work</a><a href="/watch/42/2/7.html">Wrong line</a>
            <a href="https://evil.example/watch/42/1/7.html">Foreign host</a>
          </div>
          <div class="anthology-list-box"><a href="/watch/42/2/7.html">Mirror seven</a></div>
        </div>
        """

    func testXiFanCatalogPreservesExactSparseEpisodesAndSelectedLine() async throws {
        let fixture = HTTPFixture { request in
            switch request.url!.path {
            case "/bangumi/42.html": return Self.response(request, Self.xiFanDetail)
            case "/static/js/playerconfig.js":
                return Self.response(request, #"MacPlayerConfig.player_list={"direct":{"parse":""}},MacPlayerConfig.downer_list={"notAPlayer":{"parse":""}};"#)
            case "/watch/42/1/7.html":
                return Self.response(request, try Self.player(line: 1, episode: 7, from: "direct", url: "https://media.example/primary.mp4"))
            case "/watch/42/2/7.html":
                return Self.response(request, try Self.player(line: 2, episode: 7, from: "direct", url: "https://media.example/mirror.m3u8?ticket=exact"))
            default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            }
        }
        let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
        let catalog = try await client.catalog(work("xifan", "https://dm1.xfdm.pro/bangumi/42.html"))
        assertLeaves(catalog, source: "xifan", title: "XiFan fixture", lines: ["Primary", "Mirror"], lineIDs: [1, 2],
                     titles: [["Episode seven", "Episode nine"], ["Mirror seven"]], pages: [
                        ["https://dm1.xfdm.pro/watch/42/1/7.html", "https://dm1.xfdm.pro/watch/42/1/9.html"],
                        ["https://dm1.xfdm.pro/watch/42/2/7.html"]], numbers: [[7, 9], [7]])
        let media = try await client.resolve(catalog.lines[1].episodes[0], in: catalog)
        XCTAssertEqual(media.absoluteString, "https://media.example/mirror.m3u8?ticket=exact")
    }

    private static func xiFanEncryptedFixture(probeStatus: Int = 206, probeBody: String = "",
                                             code: Int = 200, points: Int = 0) -> HTTPFixture {
        HTTPFixture { request in
            switch request.url!.host! {
            case "dm1.xfdm.pro":
                switch request.url!.path {
                case "/bangumi/42.html": return response(request, xiFanDetail)
                case "/static/js/playerconfig.js":
                    return response(request, #"MacPlayerConfig.player_list={"xfy2":{"parse":"https://player.moedot.net/player/index.php?code=xfdm1&url="}};"#)
                case "/watch/42/1/9.html":
                    return response(request, try player(line: 1, episode: 9, from: "xfy2", url: "https://stale.example/original.mp4", points: points))
                default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
                }
            case "player.moedot.net":
                XCTAssertEqual(request.url!.path, "/player/ec.php")
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.filter { $0.name == "url" }.map(\.value), ["https://stale.example/original.mp4"])
                // Independent desktop AES-CBC fixture; never encrypted by the decoder under test.
                return response(request, "let ConFig=" + (try json([
                    "code": code, "type": "auto", "config": ["uid": "abc123"],
                    "url": "IschXXMw1jD70Vf1G7oFAUnJJ7/iqE+Gpsw6lz0Qyku/6hMUnfQpSuqD//HkB9XE4qS/8ggwoH63gA5roApNMw=="
                ])) + ", box={};")
            case "media.example.invalid":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-63")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://player.moedot.net/")
                return response(request, probeBody, status: probeStatus)
            default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            }
        }
    }

    func testXiFanEncryptedParserUsesResponseUIDAndAcceptsDesktopSuccessCodes() async throws {
        for code in [200, 103] {
            let fixture = Self.xiFanEncryptedFixture(code: code)
            let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("xifan", "https://dm1.xfdm.pro/bangumi/42.html"))
            let media = try await client.resolve(catalog.lines[0].episodes[1], in: catalog)
            XCTAssertEqual(media.absoluteString, "https://media.example.invalid/episode%201.mp4?ticket=synthetic")
        }
    }

    func testXiFanMediaHTTPFailuresAndPaidPayloadNeverResolve() async throws {
        for (status, body, expected) in [
            (401, "expire missing", PlaybackFailure.mediaSignatureMissing),
            (401, "unauthorized", .authenticationRequired), (403, "forbidden", .httpForbidden),
            (404, "missing", .mediaNotFound), (410, "gone", .mediaNotFound),
            (503, "unavailable", .playerServiceUnavailable)
        ] {
            let fixture = Self.xiFanEncryptedFixture(probeStatus: status, probeBody: body)
            let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("xifan", "https://dm1.xfdm.pro/bangumi/42.html"))
            await failure(expected) { _ = try await client.resolve(catalog.lines[0].episodes[1], in: catalog) }
        }
        for (code, points, expected) in [(403, 0, PlaybackFailure.playerServiceUnavailable), (200, 1, .mediaNotFound)] {
            let fixture = Self.xiFanEncryptedFixture(code: code, points: points)
            let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("xifan", "https://dm1.xfdm.pro/bangumi/42.html"))
            await failure(expected) { _ = try await client.resolve(catalog.lines[0].episodes[1], in: catalog) }
        }
    }

    func testXiFanLegacyHTTPSMigrationRequiresUnredirectedMP4Magic() async throws {
        for mode in 0...2 {
            let fixture = HTTPFixture { request in
                switch request.url!.host! {
                case "dm1.xfdm.pro":
                    switch request.url!.path {
                    case "/bangumi/42.html": return Self.response(request, Self.xiFanDetail)
                    case "/static/js/playerconfig.js":
                        return Self.response(request, #"MacPlayerConfig.player_list={"direct":{"parse":""}};"#)
                    case "/watch/42/1/9.html":
                        return Self.response(request, try Self.player(line: 1, episode: 9, from: "direct",
                            url: "https://play.xfvod.pro:8088/archive/episode.mp4?ticket=fixture"))
                    default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
                    }
                case "play.xfvod.pro":
                    XCTAssertNil(request.url!.port)
                    XCTAssertEqual(request.url!.query, "ticket=fixture")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-63")
                    let prefix = mode == 1 ? Data("<html>not media</html>".utf8) :
                        Data([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109])
                    let final = mode == 2 ? URL(string: "https://play.xfvod.pro/redirected.mp4")! : request.url!
                    return SourceHTTPResponse(data: prefix, url: final, statusCode: 206)
                default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
                }
            }
            let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("xifan", "https://dm1.xfdm.pro/bangumi/42.html"))
            if mode == 0 {
                let media = try await client.resolve(catalog.lines[0].episodes[1], in: catalog)
                XCTAssertEqual(media.absoluteString, "https://play.xfvod.pro/archive/episode.mp4?ticket=fixture")
            } else {
                await failure(.invalidPlayerData) { _ = try await client.resolve(catalog.lines[0].episodes[1], in: catalog) }
            }
        }
    }

    private static func nextHTML() throws -> String {
        let detail: [String: Any] = ["anime": ["id": 44, "title": "Next fixture"], "sources": [
            ["id": 4, "code": "xfxf1", "name": "Main", "episodes": [["id": 501, "title": "Episode 7"]]],
            ["id": 8, "code": "AL", "name": "Alternate", "episodes": [["id": 777, "title": "Episode 7"], ["id": 801, "title": "Episode 8"]]]
        ]]
        let flight = "1:" + (try json(detail)) + "\n"
        let split = flight.index(flight.startIndex, offsetBy: flight.count / 2)
        return try [String(flight[..<split]), String(flight[split...])].map {
            "<script>self.__next_f.push(" + (try json([1, $0])) + ")</script>"
        }.joined()
    }

    func testXiFanNextCatalogUsesGlobalEpisodeAndSourceIdentityForPOST() async throws {
        let html = try Self.nextHTML()
        let fixture = HTTPFixture { request in
            switch request.url!.host! {
            case "next.xifanacg.com": return Self.response(request, html)
            case "api.xifanacg.com":
                XCTAssertEqual(request.url!.path, "/functions/v1/issue-web-playback")
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://next.xifanacg.com")
                XCTAssertNotNil(request.value(forHTTPHeaderField: "apikey"))
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                XCTAssertEqual(body?["action"] as? String, "fallback")
                XCTAssertEqual(body?["source_id"] as? Int, 8)
                XCTAssertEqual(body?["episode_id"] as? Int, 801)
                return Self.response(request, try Self.json([
                    "ok": true, "anime_id": 44, "episode_id": 801, "url": "https://media.example/next.mp4?sign=fixture",
                    "candidates": [["source_id": 8, "url": "https://media.example/next.mp4?sign=fixture"]]
                ]))
            case "media.example":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-")
                XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
                XCTAssertNil(request.value(forHTTPHeaderField: "apikey"))
                return Self.response(request, "", status: 206)
            default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            }
        }
        let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
        let catalog = try await client.catalog(work("xifan", "https://next.xifanacg.com/anime/44"))
        assertLeaves(catalog, source: "xifan", title: "Next fixture", lines: ["Main", "Alternate"], lineIDs: [1, 2],
                     titles: [["Episode 7"], ["Episode 7", "Episode 8"]], pages: [
                        ["https://next.xifanacg.com/anime/44/play/501?source=xfxf1"],
                        ["https://next.xifanacg.com/anime/44/play/777?source=AL", "https://next.xifanacg.com/anime/44/play/801?source=AL"]],
                     numbers: [[501], [777, 801]])
        let media = try await client.resolve(catalog.lines[1].episodes[1], in: catalog)
        XCTAssertEqual(media.absoluteString, "https://media.example/next.mp4?sign=fixture")
    }

    func testXiFanNextRejectsCrossEpisodeAPIResponseAndHTTPFailures() async throws {
        let html = try Self.nextHTML()
        for (status, wrongEpisode, expected) in [
            (401, false, PlaybackFailure.authenticationRequired), (403, false, .httpForbidden),
            (503, false, .playerServiceUnavailable), (200, true, .missingEpisode)
        ] {
            let fixture = HTTPFixture { request in
                if request.url!.host == "next.xifanacg.com" { return Self.response(request, html) }
                guard request.url!.host == "api.xifanacg.com" else { throw FixtureError.unexpectedRequest(request.url!.absoluteString) }
                return Self.response(request, try Self.json([
                    "ok": true, "anime_id": 44, "episode_id": wrongEpisode ? 999 : 501,
                    "url": "https://media.example/next.mp4", "candidates": [["source_id": 4, "url": "https://media.example/next.mp4"]]
                ]), status: status)
            }
            let client = NativeSourceClient(sourceID: "xifan", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("xifan", "https://next.xifanacg.com/anime/44"))
            await failure(expected) { _ = try await client.resolve(catalog.lines[0].episodes[0], in: catalog) }
        }
    }

    private static let haixingDetail = """
        <h1>Haixing fixture</h1><div class="thumb"><img src="/cover.jpg"></div>
        <div class="movurl"><ul><li><a href="/play/Ab42-1-3.html">Episode one</a></li></ul></div>
        <div class="movurl"><ul>
          <li><a href="/play/Ab42-0-0.html" title="Episode one"></a></li>
          <li><a href="/play/Ab42-0-0.html">Duplicate</a></li>
          <li><a href="/play/Ab42-0-2.html">Episode three</a></li>
          <li><a href="/play/Other-0-0.html">Other work</a></li>
          <li><a href="/play/Ab42-2-0.html">Mixed line</a></li>
        </ul></div>
        <div class="movurl"><ul><li>No resource</li></ul></div>
        """

    private static func haixingHex(_ text: String) -> String {
        // Fixture encoder is the inverse of the published reversed-byte offset format.
        Array(text.utf8).reversed().enumerated().map { index, byte in
            String(format: "%02x", (Int(byte) + 2371 + text.utf8.count - 1 - index) % 256)
        }.joined()
    }

    private static func haixingFixture(invalid: Bool = false, media: String = "https://media.example/海星.m3u8?ticket=fixture",
                                       hex: Bool = true) -> HTTPFixture {
        HTTPFixture { request in
            switch request.url!.path {
            case "/view/Ab42.html": return response(request, haixingDetail)
            case "/time": return response(request, "1700000000\n")
            case "/playinfo":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "aid" }?.value, "Ab42")
                if let cookie = request.value(forHTTPHeaderField: "Cookie") {
                    XCTAssertTrue(cookie.contains("t1=1700000000000"))
                    XCTAssertTrue(cookie.contains("k1=fixture"))
                    for name in ["k2=", "t2=", "m2t=", "im=", "kr="] { XCTAssertTrue(cookie.contains(name)) }
                    let line = query.first { $0.name == "playindex" }!.value!
                    let episode = query.first { $0.name == "epindex" }!.value!
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.haixingdmx.com/play/Ab42-\(line)-\(episode).html")
                    let payload = try json(["vurl": media, "purl": "https://parser.example/not-media", "inv": invalid ? "1" : "0"])
                    return response(request, hex ? haixingHex(payload) : payload)
                }
                return response(request, "challenge", headers: ["Set-Cookie": "t1=1700000000000; Path=/, k1=fixture; Path=/"])
            default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            }
        }
    }

    func testHaixingZeroBasedCatalogDeduplicatesAndResolvesChallengeHexPayload() async throws {
        let fixture = Self.haixingFixture()
        let client = NativeSourceClient(sourceID: "haixing", fetch: { try await fixture.fetch($0) })
        let catalog = try await client.catalog(work("haixing", "https://www.haixingdmx.com/view/Ab42.html"))
        assertLeaves(catalog, source: "haixing", title: "Haixing fixture", lines: ["播放Ⅰ", "播放Ⅱ"], lineIDs: [0, 1],
                     titles: [["Episode one", "Episode three"], ["Episode one"]], pages: [
                        ["https://www.haixingdmx.com/play/Ab42-0-0.html", "https://www.haixingdmx.com/play/Ab42-0-2.html"],
                        ["https://www.haixingdmx.com/play/Ab42-1-3.html"]], numbers: [[0, 2], [3]])
        let media = try await client.resolve(catalog.lines[0].episodes[0], in: catalog)
        XCTAssertEqual(media, URL(string: "https://media.example/海星.m3u8?ticket=fixture"))
        let requests = await fixture.recorded()
        let alternatives = requests.filter {
            $0.url?.path == "/playinfo" && $0.value(forHTTPHeaderField: "Cookie") != nil &&
                URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "playindex", value: "1")) == true
        }
        XCTAssertEqual(alternatives.count, 1, "Alternative line must match episode title, not zero-based episode index")
        XCTAssertEqual(URLComponents(url: alternatives[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "epindex" }?.value, "3")
    }

    func testHaixingRawJSONSelectsVideoURLInsteadOfParserURL() async throws {
        let fixture = Self.haixingFixture(media: "https://media.example/raw.mkv?ticket=fixture", hex: false)
        let client = NativeSourceClient(sourceID: "haixing", fetch: { try await fixture.fetch($0) })
        let catalog = try await client.catalog(work("haixing", "https://www.haixingdmx.com/view/Ab42.html"))
        let media = try await client.resolve(catalog.lines[0].episodes[1], in: catalog)
        XCTAssertEqual(media.absoluteString, "https://media.example/raw.mkv?ticket=fixture")
    }

    func testHaixingInvalidAndInsecurePayloadsNeverBecomeMedia() async throws {
        for (invalid, media) in [(true, "https://media.example/episode.mp4"), (false, "http://media.example/episode.mp4"),
                                 (false, "https://user:pass@media.example/episode.mp4"), (false, "https://media.example/landing.html")] {
            let fixture = Self.haixingFixture(invalid: invalid, media: media)
            let client = NativeSourceClient(sourceID: "haixing", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("haixing", "https://www.haixingdmx.com/view/Ab42.html"))
            await failure(.mediaNotFound) { _ = try await client.resolve(catalog.lines[0].episodes[0], in: catalog) }
        }
    }

    private static let hanimePage = """
        <h3 class="video-details-wrapper">Hanime fixture</h3><meta property="og:image" content="/cover.jpg">
        <video id="player">
          <source size="720" src="https://media.example/720.mp4?ticket=fixture">
          <source size="1080" src="/media/1080.mp4">
          <source size="480" src="http://media.example/480.mp4">
          <source size="360" src="https://user:pass@media.example/360.mp4">
          <source size="240" src="https://media.example/240.m3u8">
          <source size="0" src="https://media.example/zero.mp4">
          <source size="bad" src="https://media.example/bad.mp4">
        </video>
        """

    func testHanimeCatalogExposesOnlyActualMP4QualitiesAndResolvesEach() async throws {
        let fixture = HTTPFixture { request in
            guard request.url!.absoluteString == "https://hanime1.me/watch?v=42" else { throw FixtureError.unexpectedRequest(request.url!.absoluteString) }
            return Self.response(request, Self.hanimePage)
        }
        let client = NativeSourceClient(sourceID: "hanime1", fetch: { try await fixture.fetch($0) })
        let catalog = try await client.catalog(work("hanime1", "https://hanime1.me/watch?v=42"))
        assertLeaves(catalog, source: "hanime1", title: "Hanime fixture", lines: ["Hanime fixture"], lineIDs: [0],
                     titles: [["1080p", "720p"]], pages: [["https://hanime1.me/watch?v=42", "https://hanime1.me/watch?v=42"]],
                     numbers: [[1, 1]])
        let episodes = catalog.lines.flatMap(\.episodes)
        XCTAssertEqual(episodes.map(\.qualityID), ["1080p", "720p"])
        XCTAssertEqual(episodes.map(\.identity), Array(repeating: "hanime1:video:https://hanime1.me/watch?v=42", count: 2))
        for episode in episodes {
            XCTAssertEqual(episode.item.sourceID, "hanime1")
            let media = try await client.resolve(episode, in: catalog)
            switch episode.qualityID {
            case "1080p": XCTAssertEqual(media.absoluteString, "https://hanime1.me/media/1080.mp4")
            case "720p": XCTAssertEqual(media.absoluteString, "https://media.example/720.mp4?ticket=fixture")
            default: XCTFail("Unexpected Hanime quality")
            }
        }
    }

    func testHanimeRejectsPagesWithoutSupportedQualityMedia() async throws {
        let client = NativeSourceClient(sourceID: "hanime1", fetch: { request in
            Self.response(request, """
                <meta name="title" content="Unavailable fixture"><video id="player">
                <source size="720" src="http://media.example/insecure.mp4">
                <source size="1080" src="https://media.example/not-mp4.m3u8">
                </video>
                """)
        })
        await failure(.mediaNotFound) { _ = try await client.catalog(work("hanime1", "https://hanime1.me/watch?v=42")) }
    }

    func testComplexSourcesPreserveCatalogHTTPFailures() async throws {
        for (source, page) in [
            ("xifan", "https://dm1.xfdm.pro/bangumi/42.html"),
            ("haixing", "https://www.haixingdmx.com/view/Ab42.html"),
            ("hanime1", "https://hanime1.me/watch?v=42"),
            ("didahd", "https://www.didahd.xyz/detail/42.html")
        ] {
            for (status, expected) in [(401, PlaybackFailure.authenticationRequired), (403, .httpForbidden), (503, .playerServiceUnavailable)] {
                let client = NativeSourceClient(sourceID: source, fetch: { Self.response($0, "rejected", status: status) })
                await failure(expected) { _ = try await client.catalog(work(source, page)) }
            }
        }
    }

    private static let didahdDetail = """
        <div class="myui-content__detail"><h1 class="title">Didahd fixture</h1></div>
        <a href="#playlist1">Public web</a><a href="#playlist2">Cloud drive</a><a href="#playlist3">Paid</a>
        <div id="playlist1"><a href="/play/42-2-7.html">Episode seven</a><a href="/play/42-2-9.html">Episode nine</a>
          <a href="/play/43-2-7.html">Other work</a><a href="/play/42-3-7.html">Wrong line</a></div>
        <div id="playlist2"><a href="/play/42-4-7.html">Unsupported</a></div>
        <div id="playlist3"><a href="/play/42-5-7.html">Paid</a></div>
        """

    private static func didahdFixture(smart: Bool = false, unsupportedScript: Bool = false,
                                      ambiguous: Bool = false) -> HTTPFixture {
        HTTPFixture { request in
            switch URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path {
            case "/detail/42.html": return response(request, didahdDetail)
            case "/play/42-2-7.html", "/play/42-2-9.html":
                return response(request, try player(line: 2, episode: request.url!.path.contains("-9.") ? 9 : 7, from: "BBA", url: "aabbcc", encrypt: 3))
            case "/play/42-4-7.html": return response(request, try player(line: 4, episode: 7, from: "cloud", url: "aabbcc", encrypt: 3))
            case "/play/42-5-7.html": return response(request, try player(line: 5, episode: 7, from: "BBA", url: "aabbcc", encrypt: 3, points: 1))
            case "/static/player/BBA.js":
                return response(request, unsupportedScript ? "unsupported player" : "player='/static/player/artplayer/?url=';")
            case "/static/player/artplayer/":
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "url", value: "aabbcc")])
                if smart {
                    return response(request, #"const timestamp="1700000000";const isSmartPlay=true;const playPageUrl="fixture-vkey";const secretKeySeed="fixture-code";"#)
                }
                let entry = ["url": "Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M="]
                return response(request, "const timestamp=\"1700000000\";const qualities=" + (try json(ambiguous ? [entry, entry] : [entry])) + ";")
            case "/smartplay-cache/api/webvideo_ty.php":
                XCTAssertEqual(request.url, PublicPlayerProtocol.smartAPI)
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://www.didahd.xyz")
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
                XCTAssertEqual(body?["vkey"] as? String, "fixture-vkey")
                XCTAssertEqual(body?["code"] as? String, "fixture-code")
                let timestamp = try XCTUnwrap(body?["t"] as? Int)
                XCTAssertEqual(body?["signature"] as? String, PublicPlayerProtocol.md5(String(timestamp)))
                return response(request, #"{"code":200,"url":"Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M="}"#)
            default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            }
        }
    }

    func testDidahdCatalogFiltersUnsupportedAndPaidLinesAndResolvesPublicAESBranches() async throws {
        for smart in [false, true] {
            let fixture = Self.didahdFixture(smart: smart)
            let client = NativeSourceClient(sourceID: "didahd", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("didahd", "https://www.didahd.xyz/detail/42.html"))
            assertLeaves(catalog, source: "didahd", title: "Didahd fixture", lines: ["Public web"], lineIDs: [2],
                         titles: [["Episode seven", "Episode nine"]],
                         pages: [["https://www.didahd.xyz/play/42-2-7.html", "https://www.didahd.xyz/play/42-2-9.html"]], numbers: [[7, 9]])
            let media = try await client.resolve(catalog.lines[0].episodes[1], in: catalog)
            XCTAssertEqual(media.absoluteString, "https://media.example/video.mp4")
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.filter { $0.url?.path == "/detail/42.html" }.count, 1,
                           "Resolving must reuse the recently verified catalog instead of probing every line again")
            XCTAssertFalse(requests.contains { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.path == "/static/player/artplayer/" && $0.url?.query?.contains("url=") != true })
            XCTAssertFalse(requests.contains { $0.url?.path.contains("secure.php") == true }, "Public branches must not enter the WebKit token branch")
        }
    }

    func testPublicPlayerMP4ProbeAuthorizesRedirectUsingOriginalRange() async throws {
        let media = URL(string: "https://fixture.byteimg.com/video.image?mime_type=video_mp4")!
        let permitted = URL(string: "https://redirect.byteimg.com/final.image?mime_type=video_mp4")!
        let page = URL(string: "https://www.didahd.xyz/play/42-2-7.html")!
        let payload: [String: Any] = [
            "id": "42", "sid": 2, "nid": 7, "from": "BBA", "url": "aabbcc", "encrypt": 3
        ]
        for final in [
            permitted,
            URL(string: "http://redirect.byteimg.com/final.image?mime_type=video_mp4")!,
            URL(string: "https://user:pass@redirect.byteimg.com/final.image?mime_type=video_mp4")!,
            URL(string: "https://evil.example/final.image?mime_type=video_mp4")!
        ] {
            let fixture = HTTPFixture { request in
                switch URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path {
                case "/static/player/BBA.js":
                    return Self.response(request, "player='/static/player/artplayer/?url=';")
                case "/static/player/artplayer/":
                    // The fixed public protocol also accepts an HTTPS qualities value
                    // directly; no test-only media encryption or decoder mock is needed.
                    return Self.response(request, #"const timestamp="1700000000";const qualities=[{"url":"https://fixture.byteimg.com/video.image?mime_type=video_mp4"}];"#)
                case "/video.image":
                    XCTAssertEqual(request.url, media)
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-63")
                    return SourceHTTPResponse(
                        data: Data([0, 0, 0, 24, 102, 116, 121, 112, 105, 115, 111, 109]),
                        url: final, statusCode: 206)
                default: throw FixtureError.unexpectedRequest(request.url!.absoluteString)
                }
            }
            if final == permitted {
                let resolved = try await AccountHTTP.$currentFetch.withValue({ try await fixture.fetch($0) }) {
                    try await PublicPlayerProtocol.resolveDesktop(payload, page: page)
                }
                XCTAssertEqual(resolved, media)
            } else {
                await failure(.sourceRedirect) {
                    _ = try await AccountHTTP.$currentFetch.withValue({ try await fixture.fetch($0) }) {
                        try await PublicPlayerProtocol.resolveDesktop(payload, page: page)
                    }
                }
            }
            let requests = await fixture.recorded()
            XCTAssertEqual(requests.count, 3)
            XCTAssertEqual(requests.filter { $0.url == media }.count, 1,
                           "The real public-player branch must perform its bounded MP4 probe")
        }
    }

    func testDidahdRejectsUnrecognizedPlayerAndAmbiguousQualities() async throws {
        for (unsupported, ambiguous, expected) in [(true, false, PlaybackFailure.unsupportedEncryption), (false, true, .ambiguousMedia)] {
            let fixture = Self.didahdFixture(unsupportedScript: unsupported, ambiguous: ambiguous)
            let client = NativeSourceClient(sourceID: "didahd", fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work("didahd", "https://www.didahd.xyz/detail/42.html"))
            await failure(expected) { _ = try await client.resolve(catalog.lines[0].episodes[0], in: catalog) }
        }
    }

    func testDidahdProxyRewritesPlaylistAndStripsOnlyValidatedPNGEnvelope() async throws {
        let remote = URL(string: "https://www.didahd.xyz/video_m3u8/secure.php?skey=fixture.m3u8")!
        var ts = Data(repeating: 0, count: 188 * 3)
        for offset in stride(from: 0, to: ts.count, by: 188) { ts[offset] = 0x47 }
        let expectedTS = ts
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10, 73, 69, 78, 68, 174, 66, 96, 130])
        let wrapped = png + ts
        let fixture = HTTPFixture { request in
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            if request.url == remote {
                return Self.response(request, "#EXTM3U\n#EXTINF:4,\nhttps://file.icve.com.cn/bk/first.png\n#EXTINF:4,\nhttps://file.icve.com.cn/rc/second.png\n#EXT-X-ENDLIST\n")
            }
            guard request.url!.host == "file.icve.com.cn" else { throw FixtureError.unexpectedRequest(request.url!.absoluteString) }
            return SourceHTTPResponse(data: wrapped, url: request.url!, statusCode: 200)
        }
        let proxy = DidahdProxy()
        let localString = try await proxy.register(remote, fetch: { try await fixture.fetch($0) })
        let local = try XCTUnwrap(URL(string: localString))
        XCTAssertEqual(local.scheme, "http")
        XCTAssertEqual(local.host, "127.0.0.1")
        let owned = await proxy.ownsPlaylist(local)
        XCTAssertTrue(owned)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (playlist, playlistResponse) = try await session.data(from: local)
        let playlistHTTP = try XCTUnwrap(playlistResponse as? HTTPURLResponse)
        XCTAssertEqual(playlistHTTP.statusCode, 200)
        XCTAssertEqual(playlistHTTP.value(forHTTPHeaderField: "Content-Type"), "application/vnd.apple.mpegurl")
        XCTAssertEqual(playlist, Data("#EXTM3U\n#EXTINF:4,\n0.ts\n#EXTINF:4,\n1.ts\n#EXT-X-ENDLIST\n".utf8))

        let segmentURL = local.deletingLastPathComponent().appendingPathComponent("1.ts")
        let (segment, segmentResponse) = try await session.data(from: segmentURL)
        let segmentHTTP = try XCTUnwrap(segmentResponse as? HTTPURLResponse)
        XCTAssertEqual(segmentHTTP.statusCode, 200)
        XCTAssertEqual(segmentHTTP.value(forHTTPHeaderField: "Content-Type"), "video/mp2t")
        XCTAssertEqual(segment, expectedTS)

        let unknownToken = local.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("unknown-token").appendingPathComponent("index.m3u8")
        for missing in [
            local.deletingLastPathComponent().appendingPathComponent("2.ts"),
            local.deletingLastPathComponent().appendingPathComponent("unknown.m3u8"),
            unknownToken
        ] {
            let (body, response) = try await session.data(from: missing)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertTrue((400..<500).contains(http.statusCode), "Unknown routes must deny media access")
            XCTAssertTrue(body.isEmpty, "Unknown routes must not expose playlist or segment data")
        }
        let foreign = await proxy.ownsPlaylist(URL(string: local.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"))!)
        XCTAssertFalse(foreign)
    }

    func testDidahdProxyRejectsUnsupportedPlaylistAndMalformedSegments() async throws {
        let remote = URL(string: "https://www.didahd.xyz/video_m3u8/secure.php?skey=fixture.m3u8")!
        for text in [
            "not a playlist", "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://file.icve.com.cn/bk/key.png\"\n",
            "#EXTM3U\nhttps://evil.example/bk/segment.png\n", "#EXTM3U\nhttps://file.icve.com.cn/other/segment.png\n",
            "#EXTM3U\nhttps://file.icve.com.cn/bk/child.m3u8\n", "#EXTM3U\nrelative.png\n"
        ] {
            let proxy = DidahdProxy()
            await failure(.mediaNotFound) { _ = try await proxy.register(remote, fetch: { Self.response($0, text) }) }
        }
        let proxy = DidahdProxy()
        let localString = try await proxy.register(remote, fetch: { request in
            if request.url == remote { return Self.response(request, "#EXTM3U\nhttps://file.icve.com.cn/bk/segment.png\n") }
            return Self.response(request, "this is not PNG-wrapped MPEG-TS")
        })
        let local = try XCTUnwrap(URL(string: localString))
        await failure(.mediaNotFound) {
            _ = try await proxy.response(for: local.deletingLastPathComponent().appendingPathComponent("0.ts").path)
        }
        await failure(.mediaNotFound) {
            _ = try await proxy.register(URL(string: "https://evil.example/video_m3u8/secure.php")!, fetch: { request in
                XCTFail("Invalid proxy origin must fail before fetching")
                return Self.response(request, "")
            })
        }
    }

    func testComplexClientsRejectForeignEpisodesAndUnlistedSelections() async throws {
        let entries: [(String, String, HTTPFixture)] = [
            ("xifan", "https://dm1.xfdm.pro/bangumi/42.html", Self.xiFanEncryptedFixture()),
            ("haixing", "https://www.haixingdmx.com/view/Ab42.html", Self.haixingFixture()),
            ("hanime1", "https://hanime1.me/watch?v=42", HTTPFixture { Self.response($0, Self.hanimePage) }),
            ("didahd", "https://www.didahd.xyz/detail/42.html", Self.didahdFixture())
        ]
        for (source, page, fixture) in entries {
            let client = NativeSourceClient(sourceID: source, fetch: { try await fixture.fetch($0) })
            let catalog = try await client.catalog(work(source, page))
            let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
            let foreign = RuntimeEpisode(
                item: SourceItemRef(sourceID: "foreign-source", pageURL: selected.item.pageURL, kind: selected.item.kind),
                title: selected.title, line: selected.line, number: selected.number,
                identity: selected.identity, mediaPath: selected.mediaPath, qualityID: selected.qualityID)
            let before = await fixture.recorded().count
            await failure(.missingEpisode) { _ = try await client.resolve(foreign, in: catalog) }
            let unlisted = RuntimeEpisode(item: selected.item, title: selected.title, line: selected.line,
                                          number: selected.number + 1000, identity: selected.identity,
                                          mediaPath: selected.mediaPath, qualityID: selected.qualityID)
            await failure(.missingEpisode) { _ = try await client.resolve(unlisted, in: catalog) }
            let after = await fixture.recorded().count
            XCTAssertEqual(after, before, "Invalid selections must fail before source requests")
        }
    }

    func testComplexClientsRejectCrossSourceWorksBeforeFetching() async throws {
        let wrongWork = try work("xifan", "https://dm1.xfdm.pro/bangumi/42.html")
        for source in ["haixing", "hanime1", "didahd"] {
            let client = NativeSourceClient(sourceID: source, fetch: { request in
                XCTFail("Cross-source input must fail before HTTP")
                throw FixtureError.unexpectedRequest(request.url!.absoluteString)
            })
            await failure(.missingEpisode) { _ = try await client.catalog(wrongWork) }
        }
        let foreign = try work("haixing", "https://www.haixingdmx.com/view/Ab42.html")
        let client = NativeSourceClient(sourceID: "xifan", fetch: { request in
            XCTFail("Cross-source input must fail before HTTP")
            throw FixtureError.unexpectedRequest(request.url!.absoluteString)
        })
        await failure(.missingEpisode) { _ = try await client.catalog(foreign) }
    }
}
