import Foundation
@testable import IINA_ANI

@main enum SourceSearchRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func spec(_ json: String) throws -> SourceConfiguration.Search {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Sources/internet-archive.json")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as! [String: Any]
        root["hosts"] = ["archive.org", "search.example", "video.example"]
        root["search"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
        return try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: root)).search!
    }
    @MainActor static func main() async throws {
        let html = try spec(#"{"url":"https://search.example/find?wd={query}","format":"html","queryParameter":"wd","pageParameter":"page","rowsPerPage":20,"resultsSelector":".result","titleSelector":".name","linkSelector":"a","coverSelector":"img","coverAttribute":"data-src","hrefAttribute":"href","nextPageSelector":"a.next"}"#)
        let url = try SourceSearchExecutor.requestURL(html, query: "航海王 & /", page: 3, allowedHosts: ["search.example"])
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        try require(query.first { $0.name == "wd" }?.value == "航海王 & /" && query.first { $0.name == "page" }?.value == "3", "query encoding must not inject parameters or lose pagination")
        do {
            _ = try SourceSearchExecutor.requestURL(html, query: "title", page: 1, allowedHosts: ["search.example.attacker.invalid"])
            throw Failure.assertion("lookalike host accepted")
        } catch SourceSearchError.invalidConfiguration {}
        let markup = """
        <html><body><div class="result"><a href="/work/17"><img data-src="//images.example/17.jpg"></a><span class="name"> A &amp; B </span></div>
        <div class="result"><a href="/work/17"></a><span class="name"> A &amp; B </span></div><a class="next" href="?wd=title&page=2">Next</a></body></html>
        """
        let classification = MediaClassification(kind: .anime, provenance: "fixture-schema")
        let page = try SourceSearchExecutor.parse(data: Data(markup.utf8), spec: html, page: 1, responseURL: url,
                                                 classification: { _ in classification }) {
            guard let parsed = URL(string: $0), parsed.host == "search.example" else { return nil }
            return SourceItemRef(sourceID: "example", pageURL: parsed.absoluteString, kind: .work)
        }
        try require(page.results.count == 1 && page.results[0].title == "A & B" && page.results[0].item.pageURL == "https://search.example/work/17", "separate title/link selectors must preserve normalized identity and dedupe rows")
        try require(page.results[0].cover == "https://images.example/17.jpg" && page.nextPage == 2, "relative covers and explicit next-page links must be resolved")
        try require(page.results[0].classification == classification, "HTML search dropped schema evidence")
        let empty = try SourceSearchExecutor.parse(data: Data("<html><body>No results</body></html>".utf8), spec: html, page: 1, responseURL: url) { _ in nil }
        try require(empty.results.isEmpty && empty.nextPage == nil, "valid empty HTML must stay distinct from transport failure")
        do {
            _ = try SourceSearchExecutor.parse(data: Data("<html><head><title>Just a moment...</title></head><body><form id='challenge-form'></form></body></html>".utf8), spec: html, page: 1, responseURL: url) { _ in nil }
            throw Failure.assertion("challenge page was reported as empty")
        } catch SourceSearchError.malformedResponse {}
        let zeroBased = try spec(#"{"url":"https://search.example/find?wd={query}","format":"html","queryParameter":"wd","pageParameter":"pageindex","firstPage":0,"rowsPerPage":24,"resultsSelector":".result","titleSelector":".name","hrefAttribute":"href","rejectSelectors":["title:contains(系统安全验证)"]}"#)
        for (cursor, index) in [(1, "0"), (2, "1")] {
            let address = try SourceSearchExecutor.requestURL(zeroBased, query: "A & B", page: cursor, allowedHosts: ["search.example"])
            let fields = URLComponents(url: address, resolvingAgainstBaseURL: false)!.queryItems!
            try require(fields.contains { $0.name == "pageindex" && $0.value == index } && fields.contains { $0.name == "wd" && $0.value == "A & B" }, "zero-based source paging must preserve one-based consumer cursors and encoded query")
        }
        do {
            _ = try SourceSearchExecutor.parse(data: Data("<html><head><title>系统安全验证</title></head><body>Captcha</body></html>".utf8), spec: zeroBased, page: 1, responseURL: url) { _ in nil }
            throw Failure.assertion("site challenge page was reported as empty")
        } catch SourceSearchError.malformedResponse {}
        let json = try spec(#"{"url":"https://search.example/api","format":"json","queryParameter":"keyword","pageParameter":"page","rowsPerPage":20,"jsonResultsPath":"data.result","jsonTitlePath":"title","jsonIdentifierPath":"id","jsonCoverPath":"pic","jsonTotalPath":"data.total"}"#)
        let results = #"{"data":{"total":40,"result":[{"id":"17","title":"<em>A</em> &amp; B","pic":"//images.example/17.jpg"}]}}"#
        let videos = try SourceSearchExecutor.parse(data: Data(results.utf8), spec: json, page: 1, responseURL: url, resultURLTemplate: "https://video.example/watch/{id}",
                                                   classification: { _ in MediaClassification(kind: .video, provenance: "fixture-json") }) {
            SourceItemRef(sourceID: "example", pageURL: $0, kind: .video)
        }
        try require(videos.results[0].title == "A & B" && videos.results[0].item.pageURL == "https://video.example/watch/17" && videos.nextPage == 2, "JSON identifiers must expand to playable page URLs, strip highlight markup, and retain pagination")
        try require(videos.results[0].classification.kind == .video && videos.results[0].classification.provenance == "fixture-json", "JSON search dropped content evidence")
        do {
            _ = try SourceSearchExecutor.parse(data: Data("{not-json".utf8), spec: json, page: 1, responseURL: url) { _ in nil }
            throw Failure.assertion("malformed JSON reported as empty")
        } catch SourceSearchError.malformedResponse {}
        print("PASS W7 source search: exact hosts, encoding, independent title/link selectors, canonical dedupe, explicit pagination, challenge versus empty, JSON playable identity")
    }
}
