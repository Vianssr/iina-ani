import Foundation
@testable import IINA_ANI

private final class CatalogProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "www.fqdm.cc" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let html = """
        <div class="module-info-heading"><h1>Fixture work</h1></div>
        <div class="module-tab-item tab-item"><span>First line</span></div>
        <div class="module-tab-item tab-item"><span>Second line</span></div>
        <div class="module-play-list">
          <a class="module-play-list-link" href="/index.php/vod/play/id/12/sid/1/nid/1.html">Episode 1</a>
          <a class="module-play-list-link" href="/index.php/vod/play/id/12/sid/1/nid/2.html">Episode 2</a>
        </div>
        <div class="module-play-list">
          <a class="module-play-list-link" href="/index.php/vod/play/id/12/sid/2/nid/1.html">Episode 1</a>
          <a class="module-play-list-link" href="/index.php/vod/play/id/12/sid/2/nid/2.html">Episode 2</a>
        </div>
        """
        let isPlayer = url.path.contains("/play/")
        let data = isPlayer
            ? Data(#"{"player":{"id":"12","sid":1,"nid":2,"points":0,"trysee":0,"encrypt":0,"url":"https://cdn.example/selected.mp4"}}"#.utf8)
            : Data(html.utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                      headerFields: ["Content-Type": isPlayer ? "application/json" : "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main enum ConfiguredSourceRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let definition = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [CatalogProtocol.self]
        let source = ConfiguredSource(configuration: definition, site: .configured("fqdm"), requestConfiguration: session)
        let first = "https://www.fqdm.cc/index.php/vod/play/id/12/sid/1/nid/2.html"
        let second = "https://www.fqdm.cc/index.php/vod/play/id/12/sid/2/nid/2.html"
        let firstCatalog = try await source.episodeList(first)
        let secondCatalog = try await source.episodeList(second)
        let firstLeaves = firstCatalog.nodes.flatMap(\.children)
        let secondLeaves = secondCatalog.nodes.flatMap(\.children)
        try require(firstLeaves[firstCatalog.current].selectionURL == first,
                    "matching episode numbers on another line must not replace the selected leaf")
        try require(secondLeaves[secondCatalog.current].selectionURL == second,
                    "the selected line must determine the current leaf")
        let registry = SourceRegistry(builtinDirectory: root.appendingPathComponent("IINA-ANI/Sources"),
            userDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let firstPage = "https://www.fqdm.cc/index.php/vod/play/id/12/sid/1/nid/1.html"
        let selected = PlayableSelection(item: try registry.item(for: firstPage), lineID: "1",
            qualityID: "First line (1)", accountID: UUID(),
            classification: MediaClassification(kind: .anime, provenance: "manual"))
        let next = AutoplaySelection.next(after: selected, in: firstCatalog.nodes, registry: registry)
        try require(next?.item.pageURL == first && next?.lineID == selected.lineID &&
                    next?.qualityID == selected.qualityID && next?.accountID == selected.accountID &&
                    next?.classification == selected.classification,
                    "autoplay from a parsed online catalog must retain the precise source, line, quality, account and classification")
        if let next {
            try require(AutoplaySelection.next(after: next, in: firstCatalog.nodes, registry: registry) == nil,
                        "autoplay at a parsed line's end must not cross into the next line")
        } else { throw Failure.assertion("parsed fixture did not expose the next sibling") }
        let unavailable = try await source.liveInfo("https://www.fqdm.cc/index.php/vod/play/id/12/sid/3/nid/2.html")
        try require(!unavailable.isLiving, "an episode on another line does not make a missing selected line available")
        let available = try await source.liveInfo(first)
        try require(available.isLiving && available.title == "Fixture work", "a present selected line/episode must remain available")
        do {
            _ = try await source.episodeList("https://www.fqdm.cc/index.php/vod/play/id/12/sid/3/nid/2.html")
            throw Failure.assertion("a missing selected line must be refused rather than selecting a different line")
        } catch VideoGetError.notFountData {}
        print("PASS: catalog selections and availability retain line plus episode identity")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))) as! [String: Any]
        var player = json["player"] as! [String: Any]
        player["format"] = "json"
        player["payloadPattern"] = "player"
        json["player"] = player
        let jsonDefinition = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: json))
        let jsonSession = URLSessionConfiguration.ephemeral
        jsonSession.protocolClasses = [CatalogProtocol.self]
        let jsonSource = ConfiguredSource(configuration: jsonDefinition, site: .configured("fqdm"), requestConfiguration: jsonSession)
        let resolved = try await jsonSource.decodeUrl(first)
        try require(resolved.streams["First line (1)"]?.url == "https://cdn.example/selected.mp4",
                    "a JSON object path must resolve the selected episode instead of requiring a regex capture")
        print("PASS: JSON player paths resolve the selected line and episode")
    }
}
