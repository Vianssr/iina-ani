import Foundation

@main
struct TorrentSearchRegression {
    static let base = URL(string: "https://rss.example/feed.xml")!
    static let hash = String(repeating: "a", count: 40)
    static let fixture = """
    <?xml version="1.0"?>
    <rss version="2.0" xmlns:nyaa="https://nyaa.si/xmlns/nyaa"><channel>
      <item><title><![CDATA[A & B]]></title><link>https://rss.example/view/1</link>
        <enclosure url="/download/1.torrent" type="application/x-bittorrent"/>
        <nyaa:infoHash>aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa</nyaa:infoHash></item>
      <item><title>Magnet only</title><link>magnet:?xt=urn:btih:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb&amp;dn=Test</link></item>
      <item><title>Typed download</title><enclosure url="https://rss.example/get?id=3" type="application/x-bittorrent"/></item>
      <item><title>Direct torrent</title><link>https://rss.example/a.torrent?download=1</link></item>
      <item><title>Detail only</title><link>https://rss.example/view/5</link><enclosure url="https://rss.example/detail.html" type="text/html"/></item>
      <item><title>Unsafe scheme</title><enclosure url="file:///tmp/a.torrent" type="application/x-bittorrent"/></item>
      <item><title>Invalid magnet</title><link>magnet:?xt=urn:btih:not-a-hash</link></item>
      <item><title>Garden magnet enclosure</title><link>https://rss.example/view/7</link><enclosure url="magnet:?xt=urn:btih:cccccccccccccccccccccccccccccccccccccccc&amp;tr=https%3A%2F%2Ftracker.example%2Fannounce" type="application/x-bittorrent"/></item>
      <item><title>Duplicate</title><link>https://rss.example/a.torrent?download=1</link></item>
    </channel></rss>
    """

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }
    struct Failure: Error { let message: String }

    static func rejects(_ body: () throws -> Void, _ message: String) throws {
        do { try body() } catch { return }
        throw Failure(message: message)
    }

    static func subscription(_ sources: [(String, String)], version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": sources.map { name, url in
            ["factoryId": "rss", "version": version, "arguments": ["name": name, "searchConfig": ["searchUrl": url]]] as [String: Any]
        }]])
    }

    actor FixtureTransport {
        var subscription: Data
        var requests: [URL] = []
        init(_ subscription: Data) { self.subscription = subscription }
        func replace(_ data: Data) { subscription = data }
        func fetch(_ url: URL, _ limit: Int) throws -> (Data, URL) {
            requests.append(url)
            if url == TorrentSearchService.endpoint { return (subscription, url) }
            if url.host == "fail.example" { throw TorrentSearchError.httpStatus(503) }
            if url.host == "cancel.example" { throw CancellationError() }
            return (Data(TorrentSearchRegression.fixture.utf8), url)
        }
        func subscriptionReads() -> Int { requests.filter { $0 == TorrentSearchService.endpoint }.count }
    }

    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--smoke" {
            let keyword = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "葬送"
            let report = try await TorrentSearchService().search(keyword: keyword)
            print("REAL NETWORK BT search keyword=\(keyword) results=\(report.results.count) failures=\(report.failures.count)")
            let counts = Dictionary(grouping: report.results, by: \.sourceName).mapValues(\.count)
            for name in counts.keys.sorted() { print("  \(name): \(counts[name]!) importable results") }
            for failure in report.failures { print("  FAILURE: \(failure)") }
            try require(report.results.allSatisfy { $0.magnetURL != nil || $0.torrentURL != nil }, "Every result must be importable")
            return
        }

        let keyword = "葬送 + & # / ? % \"quoted\" \\ line\n{keyword}"
        let simple = try TorrentSearchService.requestURL(template: "https://rss.example/?q={keyword}&c=0_0", keyword: keyword)
        let query = URLComponents(url: simple, resolvingAgainstBaseURL: false)!.queryItems!
        try require(query.first(where: { $0.name == "q" })?.value == keyword, "Keyword round-trips through URL encoding")
        try require(query.count == 2 && simple.absoluteString.contains("%2B") && simple.absoluteString.contains("%26"), "Keyword cannot inject query arguments or form plus")
        let jsonURL = try TorrentSearchService.requestURL(template: "https://rss.example/feed.xml?filter=[{\"type\":\"动画\",\"search\":[\"{keyword}\"]}]", keyword: keyword)
        let filter = URLComponents(url: jsonURL, resolvingAgainstBaseURL: false)!.queryItems!.first!.value!
        let object = try JSONSerialization.jsonObject(with: Data(filter.utf8)) as! [[String: Any]]
        try require(object[0]["search"] as? [String] == [keyword], "JSON filter safely escapes keyword before URL encoding")
        let pathURL = try TorrentSearchService.requestURL(template: "https://rss.example/search/{keyword}", keyword: "a/b")
        try require(pathURL.absoluteString.contains("a%2Fb"), "Path keyword cannot inject a path segment")
        for template in ["file:///tmp/{keyword}", "ftp://rss.example/{keyword}", "https://user:pass@rss.example/?q={keyword}", "https://{keyword}.example/", "https://rss.example/?q=fixed", "https://rss.example/?q={keyword}#fragment"] {
            try rejects({ _ = try TorrentSearchService.requestURL(template: template, keyword: keyword) }, "Reject unsafe or missing placeholder template")
        }

        let results = try TorrentSearchService.parseRSS(data: Data(fixture.utf8), sourceName: "Fixture", responseURL: base)
        try require(results.count == 5, "Only importable unique entries survive; HTML details and unsafe links never become torrent URLs")
        try require(results[0].title == "A & B" && results[0].sourceName == "Fixture", "CDATA titles and source identity survive")
        try require(results[0].magnetURL == "magnet:?xt=urn:btih:" + hash, "Nyaa infoHash becomes importable magnet")
        try require(results[0].torrentURL?.absoluteString == "https://rss.example/download/1.torrent", "Enclosure resolves relative to response URL")
        try require(results[1].magnetURL?.contains("&dn=Test") == true && results[1].torrentURL == nil, "RSS escaped magnet query decodes")
        try require(results[2].torrentURL?.path == "/get", "Typed torrent download need not end in .torrent")
        try require(results[4].title == "Garden magnet enclosure" && results[4].magnetURL?.contains("&tr=") == true && results[4].torrentURL == nil, "Garden magnet enclosure preserves import URL and tracker")
        let empty = try TorrentSearchService.parseRSS(data: Data("<rss><channel/></rss>".utf8), sourceName: "Empty", responseURL: base)
        try require(empty.isEmpty, "A valid empty feed is successful search with no matches")
        for xml in ["<html><body>challenge</body></html>", "<rss><channel>", "<!DOCTYPE rss [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><rss><channel><item><title>&x;</title></item></channel></rss>", "<!DOCTYPE rss [<!ENTITY x 'expanded'>]><rss><channel><item><title>&x;</title></item></channel></rss>"] {
            try rejects({ _ = try TorrentSearchService.parseRSS(data: Data(xml.utf8), sourceName: "Bad", responseURL: base) }, "Reject HTML, malformed XML and declared entities: \(xml)")
        }
        let entityXML = "<!DOCTYPE rss [<!ENTITY x SYSTEM 'https://entity.example/private'>]><rss><channel/></rss>"
        for encoding in [String.Encoding.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            try rejects({ _ = try TorrentSearchService.parseRSS(data: entityXML.data(using: encoding)!, sourceName: "Encoded", responseURL: base) }, "Reject encoded DTD before parser resolution")
        }
        try rejects({ _ = try TorrentSearchService.parseRSS(data: Data(repeating: 32, count: TorrentSearchService.feedLimit + 1), sourceName: "Huge", responseURL: base) }, "Feed size bound is enforced")

        let transport = FixtureTransport(try subscription([("Broken", "https://fail.example/?q={keyword}"), ("Working", "https://rss.example/?q={keyword}")]))
        let service = TorrentSearchService(fetch: { try await transport.fetch($0, $1) })
        let mixed = try await service.search(keyword: "Test")
        try require(mixed.results.count == 5 && mixed.failures.count == 1 && mixed.failures[0].contains("Broken") && mixed.failures[0].contains("503"), "One failed source cannot discard working results")
        try await transport.replace(subscription([("Changed", "https://rss.example/?q={keyword}")]))
        let changed = try await service.search(keyword: "Again")
        let reads = await transport.subscriptionReads()
        try require(changed.results[0].sourceName == "Changed" && reads == 2, "Each search downloads the current bt1 subscription")
        try await transport.replace(subscription([("Broken", "https://fail.example/?q={keyword}")]))
        do {
            _ = try await service.search(keyword: "Test")
            throw Failure(message: "All-source failure must throw")
        } catch TorrentSearchError.allSourcesFailed(let failures) {
            try require(failures.count == 1 && failures[0].contains("Broken"), "Complete failure names the failed source")
        }
        try await transport.replace(subscription([("Unsupported", "https://rss.example/?q={keyword}")], version: 2))
        do {
            _ = try await service.search(keyword: "Test")
            throw Failure(message: "Unsupported version must not be searched")
        } catch TorrentSearchError.allSourcesFailed(let failures) {
            try require(failures[0].contains("第 1 版"), "Unsupported source is clearly reported")
        }
        try await transport.replace(subscription([("Cancelled", "https://cancel.example/?q={keyword}"), ("Working", "https://rss.example/?q={keyword}")]))
        do {
            _ = try await service.search(keyword: "Test")
            throw Failure(message: "Cancellation must escape rather than become source failure")
        } catch is CancellationError {}
        let sleeper = TorrentSearchService(fetch: { url, _ in
            try await Task.sleep(for: .seconds(30))
            return (Data(), url)
        })
        let pending = Task { try await sleeper.search(keyword: "cancel") }
        pending.cancel()
        do {
            _ = try await pending.value
            throw Failure(message: "Caller cancellation must propagate")
        } catch is CancellationError {}
        print("PASS TorrentSearchRegression: URL/JSON escaping, RSS import parsing, HTML/entity rejection, size bounds, partial/complete failure, fresh subscription and cancellation")
    }
}
