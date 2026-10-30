import Foundation

private actor CSS1ResponseGate {
    let data: Data
    private var continuation: CheckedContinuation<Data, Never>?
    var waiting: Bool { continuation != nil }
    init(data: Data) { self.data = data }
    func fetch() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: data); continuation = nil }
}

@MainActor enum CSS1ClientRegression {
    static func run(root: URL) async throws {
        let configuration = try source()
        let searchHTML = Data("""
        <a class="result" href="/show?id=1" title="First anime"></a>
        <a class="result" href="/show?id=2">Second anime</a>
        <a class="result" href="/show?id=1#duplicate">Duplicate</a>
        <a class="result" href="https://other.example/show?id=4">Foreign</a>
        <a class="result" href="https://user:secret@fixture.example/show?id=5">Credentials</a>
        <a class="result" href="/show?id=6&amp;token=secret">Unsafe query</a>
        """.utf8)
        let page = try await MobileSourceClient(configuration: configuration) { url in
            precondition(url.host == "fixture.example")
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "作品 & 字")
            return searchHTML
        }.search("作品 & 字")
        precondition(page.works.count == 2 && page.nextPage == nil)
        precondition(page.works[0].title == "First anime")
        precondition(page.works[0].item.pageURL == "https://fixture.example/show?id=1")
        precondition(page.works[1].item.pageURL == "https://fixture.example/show?id=2")
        let work = page.works[0]
        let catalogHTML = Data("""
        <b class="line-name">Line A</b><b class="line-name">Line B</b>
        <div class="episodes"><a href="/play?id=101">Episode one</a><a href="/play?id=101#duplicate">Duplicate</a><a href="/play?id=102">Episode two</a></div>
        <div class="episodes"><a href="/play?id=201">Other line</a></div>
        """.utf8)
        let catalog = try await MobileSourceClient(configuration: configuration) { url in
            precondition(url.absoluteString == work.item.pageURL)
            return catalogHTML
        }.catalog(work)
        precondition(catalog.work == work && catalog.lines.map(\.id) == [1, 2])
        precondition(catalog.lines[0].episodes.count == 2)
        precondition(catalog.lines[0].title == "Line A")
        let episode = catalog.lines[0].episodes[0]
        precondition(episode.identity == "https://fixture.example/play?id=101")
        let media = "https://media.example/video.m3u8?signature=fixture"
        let encoded = media.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        for encoding in 0...2 {
            let value = encoding == 0 ? media : encoding == 1 ? encoded : Data(encoded.utf8).base64EncodedString()
            let payload = try player(url: value, encoding: encoding)
            let result = try await MobileSourceClient(configuration: configuration) { url in
                precondition(url.absoluteString == episode.item.pageURL)
                return payload
            }.resolve(episode, in: catalog)
            precondition(result.absoluteString == media) // Actual payload sid=2 deliberately differs from catalog line=1.
        }
        for html in ["<video src='\(media)'></video>",
                     "<video><source src='\(media)'></video>",
                     "<iframe src='https://parser.example/player?url=\(encoded)'></iframe>"] {
            let client = MobileCSS1Client(configuration: configuration, fetch: { url in
                precondition(url.host == "fixture.example") // No iframe or stream fetch is performed.
                return Data(html.utf8)
            })
            let resolved = try await client.resolve(episode: episode, catalog: catalog)
            precondition(resolved.absoluteString == media)
        }
        for invalid in [try player(url: media, encoding: 3), try player(url: media, points: 1),
                        try player(url: media, preview: 30),
                        Data("<video src='http://media.example/video.mp4'></video>".utf8),
                        Data("<video src='https://user:secret@media.example/video.mp4'></video>".utf8),
                        Data("<video src='https://media.example/a.mp4'></video><video src='https://media.example/b.mp4'></video>".utf8),
                        Data("<script>document.write('https://media.example/video.mp4')</script>".utf8),
                        Data("<iframe src='https://parser.example/execute'></iframe>".utf8)] {
            let client = MobileCSS1Client(configuration: configuration, fetch: { _ in invalid })
            await SourceRegression.rejects { _ = try await client.resolve(episode: episode, catalog: catalog) }
        }
        let neverFetch = MobileCSS1Client(configuration: configuration, fetch: { _ in preconditionFailure("Invalid identity reached transport") })
        let changed = MobileSourceEpisode(item: episode.item, title: "Changed", line: episode.line, number: episode.number, identity: episode.identity)
        await SourceRegression.rejects { _ = try await neverFetch.resolve(episode: changed, catalog: catalog) }
        let foreignWork = MobileSourceWork(item: .init(sourceID: "another", pageURL: work.item.pageURL, kind: .work), title: work.title)
        await SourceRegression.rejects { _ = try await neverFetch.catalog(work: foreignWork) }
        let foreignCatalog = MobileSourceCatalog(work: foreignWork, lines: catalog.lines)
        await SourceRegression.rejects { _ = try await neverFetch.resolve(episode: episode, catalog: foreignCatalog) }

        let noChannels = try source(channel: ["channelFormatId": "no-channel", "selectorChannelFormatNoChannel": [
            "selectEpisodes": ".episode-name", "selectEpisodeLinks": ".episode-link"]])
        let independentHTML = Data("<span class='episode-name'>One</span><a class='episode-link' href='/play?id=1'></a>".utf8)
        let independent = try await MobileCSS1Client(configuration: noChannels, fetch: { _ in independentHTML })
            .catalog(work: .init(item: .init(sourceID: noChannels.id, pageURL: work.item.pageURL, kind: .work), title: "No channels"))
        precondition(independent.lines.count == 1 && independent.lines[0].episodes[0].title == "One")
        let mismatch = MobileCSS1Client(configuration: noChannels, fetch: { _ in
            Data("<span class='episode-name'>One</span><span class='episode-name'>Two</span><a class='episode-link' href='/play?id=1'></a>".utf8)
        })
        await SourceRegression.rejects { _ = try await mismatch.catalog(work: work) }

        let indexed = try source(subject: ["subjectFormatId": "indexed", "selectorSubjectFormatIndexed": [
            "selectNames": ".name", "selectLinks": ".link"]])
        let indexedPage = try await MobileCSS1Client(configuration: indexed, fetch: { _ in
            Data("<h3 class='name'>Indexed title</h3><a class='link' href='/show?id=11'></a><a class='link' data-id='11'>Bookmark</a>".utf8)
        }).search(keyword: "test")
        precondition(indexedPage.works.first?.title == "Indexed title")
        let unequal = MobileCSS1Client(configuration: indexed, fetch: { _ in
            Data("<h3 class='name'>One</h3><h3 class='name'>Two</h3><a class='link' href='/show?id=11'></a>".utf8)
        })
        await SourceRegression.rejects { _ = try await unequal.search(keyword: "test") }

        for (namePath, linkPath) in [("$.info.rows[*].vod_name", "$.info.rows[*].vod_id"),
                                     ("$['info']['rows'][*]['vod_name']", "$['info']['rows'][*]['vod_id']")] {
            let json = try source(subject: ["subjectFormatId": "json-path-indexed", "selectorSubjectFormatJsonPathIndexed": [
                "selectNames": namePath, "selectLinks": linkPath, "linkTemplate": "/show?id={value}"]])
            let result = try await MobileCSS1Client(configuration: json, fetch: { _ in
                Data(#"{"info":{"rows":[{"vod_name":"JSON &amp; title","vod_id":42}]}}"#.utf8)
            }).search(keyword: "test")
            precondition(result.works.first?.item.pageURL == "https://fixture.example/show?id=42")
            precondition(result.works.first?.title == "JSON & title")
        }
        // Relative links follow the response page unless CSS1 supplies an explicit rawBaseUrl.
        for explicitBase in [false, true] {
            var object = try JSONSerialization.jsonObject(with: configuration.encodedData()) as! [String: Any]
            var spec = object["webSelector"] as! [String: Any]
            spec["relativeLinksUseSearchURL"] = !explicitBase
            object["webSelector"] = spec
            var search = object["search"] as! [String: Any]
            search["url"] = "https://fixture.example/catalog/search?wd={query}"
            object["search"] = search
            let relativeConfig = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object))
            let result = try await MobileCSS1Client(configuration: relativeConfig, fetch: { _ in
                Data("<a class='result' href='detail/42'>Relative</a><a class='result' href=''>Empty</a>".utf8)
            }).search(keyword: "test")
            precondition(result.works.count == 1)
            precondition(result.works[0].item.pageURL == (explicitBase ?
                "https://fixture.example/detail/42" : "https://fixture.example/catalog/detail/42"))
        }
        // Senfun's public API is tied to the exact selected episode and website default stream.
        let senfunData = String(decoding: try configuration.encodedData(), as: UTF8.self)
            .replacingOccurrences(of: "fixture.example", with: "senfun.in")
        let senfun = try MobileSourceLibrary.validate(Data(senfunData.utf8))
        let senfunWork = MobileSourceWork(item: try senfun.webItem("https://senfun.in/voddetail/42.html", kind: .work), title: "Sample")
        let senfunEpisode = MobileSourceEpisode(item: try senfun.webItem("https://senfun.in/vodwatch/42/ep1.html", kind: .episode),
            title: "1", line: 1, number: 1)
        let senfunCatalog = MobileSourceCatalog(work: senfunWork, lines: [.init(id: 1, title: "HD", episodes: [senfunEpisode])])
        for raw in [media, "http://media.example/unsafe.m3u8"] {
            let response = try JSONSerialization.data(withJSONObject: ["video_plays": [
                ["play_data": raw], ["play_data": "https://media.example/alternative.m3u8"]]])
            let client = MobileCSS1Client(configuration: senfun, fetch: { url in
                if url.path == "/vodwatch/42/ep1.html" { return Data("<div id='senfun-p'></div>".utf8) }
                precondition(url.absoluteString == "https://senfun.in/_senfun_plays/42/ep1")
                return response
            })
            if raw == media {
                let resolved = try await client.resolve(episode: senfunEpisode, catalog: senfunCatalog)
                precondition(resolved.absoluteString == media)
            } else {
                await SourceRegression.rejects { _ = try await client.resolve(episode: senfunEpisode, catalog: senfunCatalog) }
            }
        }

        let gate = CSS1ResponseGate(data: searchHTML)
        let cancellable = MobileCSS1Client(configuration: configuration, fetch: { _ in await gate.fetch() })
        let request = Task { try await cancellable.search(keyword: "test") }
        while !(await gate.waiting) { await Task.yield() }
        request.cancel()
        await gate.release()
        do { _ = try await request.value; fatalError("Late CSS1 search escaped cancellation") }
        catch is CancellationError {}
        print("PASS: CSS1 HTML/indexed/JSONPath search, canonical page identity, grouped catalog, direct media, encryption, ambiguity and cancellation")
    }

    private static func source(subject: [String: Any]? = nil, channel: [String: Any]? = nil) throws -> SourceConfiguration {
        var search: [String: Any] = ["searchUrl": "https://fixture.example/search?wd={keyword}",
            "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": "a.result"],
            "channelFormatId": "index-grouped", "selectorChannelFormatFlattened": [
                "selectChannelNames": ".line-name", "selectEpisodeLists": ".episodes", "selectEpisodesFromList": "a"]]
        for (key, value) in subject ?? [:] { search[key] = value }
        for (key, value) in channel ?? [:] { search[key] = value }
        let item: [String: Any] = ["id": "css1-engine", "factoryId": "web-selector", "version": 2,
            "arguments": ["name": "Engine fixture", "searchConfig": search]]
        return try MobileCSS1Configuration.convert(data: JSONSerialization.data(withJSONObject: ["mediaSources": [item]])).drafts[0].configuration
    }

    private static func player(url: String, encoding: Int = 0, points: Int = 0, preview: Int = 0) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: ["id": "different-site-id", "sid": 2, "nid": 19,
            "url": url, "encrypt": encoding, "points": points, "trysee": preview])
        return Data("<script>var player_aaaa=\(String(decoding: data, as: UTF8.self));</script>".utf8)
    }
}
