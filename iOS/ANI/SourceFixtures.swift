#if DEBUG
import SourceCore
import SourceRuntime
import Foundation

/// Deterministic configured JSON imports for explicit Debug fixtures.
enum MobileSourceFixtures {
    /// The real converter creates v4 rules from this export; the fixture does not synthesize a parsed plan.
    static func staticSubscriptionData() throws -> Data {
        let item: [String: Any] = ["factoryId": "web-selector", "version": 2,
            "arguments": ["name": "Static page fixture", "searchConfig": [
                "searchUrl": "https://static-fixture.example/search?q={keyword}",
                "subjectFormatId": "indexed",
                "selectorSubjectFormatIndexed": ["selectNames": ".result-name", "selectLinks": "a.result-link"],
                "channelFormatId": "index-grouped",
                "selectorChannelFormatFlattened": ["selectChannelNames": ".line-name", "selectEpisodeLists": ".episodes",
                    "selectEpisodesFromList": "a.episode"]]]]
        _ = try SourceWebConfigurationConverter.configuration(item)
        return try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [item]]])
    }

    static func configurationData() throws -> Data {
        Data(#"""
{
  "id": "fqdm",
  "name": "Tomato Anime",
  "version": 1,
  "contentKind": "anime",
  "hosts": ["fqdm.cc", "www.fqdm.cc"],
  "mediaHosts": [],
  "anonymousExternalHTTPSMedia": true,
  "credentialHosts": [],
  "capabilities": ["information", "resolve", "episodes", "lines", "iina", "mpv", "download", "search"],
  "route": {
    "pattern": "^/index\\.php/vod/(?:detail/id/|play/id/)([0-9]+)(?:\\.html|/sid/([0-9]+)/nid/([0-9]+)\\.html)$",
    "idGroup": 1,
    "lineGroup": 2,
    "episodeGroup": 3,
    "idIsPositiveInteger": true,
    "detailTemplate": "https://www.fqdm.cc/index.php/vod/detail/id/{id}.html"
  },
  "catalog": {
    "url": "https://www.fqdm.cc/index.php/vod/detail/id/{id}.html",
    "format": "html",
    "titleSelector": ".module-info-heading h1",
    "coverSelector": ".module-info-poster img",
    "coverAttribute": "data-original",
    "panelSelector": ".module-play-list",
    "lineTitleSelector": ".module-tab-item.tab-item span",
    "episodeSelector": ".module-play-list-link[href]",
    "episodeTitleSelector": "self",
    "episodeURLAttribute": "href"
  },
  "player": {
    "format": "html",
    "payloadPattern": "var\\s+player_aaaa\\s*=\\s*(\\{.*?\\})\\s*;?\\s*</script>",
    "idKey": "id",
    "lineKey": "sid",
    "episodeKey": "nid",
    "paidKey": "points",
    "previewKey": "trysee",
    "encodingKey": "encrypt",
    "urlKey": "url",
    "idIsString": true,
    "allowedExtensions": ["m3u8", "mp4"],
    "rejectSelectors": []
  },
  "search": {
    "url": "https://www.fqdm.cc/index.php/vod/search.html?wd={query}",
    "format": "html",
    "queryParameter": "wd",
    "pageParameter": "page",
    "rowsPerPage": 24,
    "nextPageSelector": "a[rel=next], a:contains(下一页), a:contains(下一頁)",
    "resultsSelector": "div.module-card-item-info > div.module-card-item-title > a",
    "titleSelector": "self",
    "hrefAttribute": "href"
  }
}
"""#.utf8)
    }
}

/// Deterministic UI transport, reachable only through an explicit Debug launch argument.
enum SourceFixtures {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-source-ui-fixture") ||
        ProcessInfo.processInfo.arguments.contains("-catalog-ui-fixture") ||
        ProcessInfo.processInfo.arguments.contains("-native-playback-ui-fixture")
    }
    static let mediaURL = URL(string: "https://media.example.test/source-fixture.mp4")!
    static func catalog(_ url: URL?) -> Data? {
        guard enabled, let url else { return nil }
        let subject = #"{"id":4242,"name":"Source Flow Fixture","summary":"Deterministic source playback fixture."}"#
        let tuesday = #"{"id":4243,"name":"Tuesday Calendar Fixture","summary":"A distinct Tuesday schedule item."}"#
        if url.path == "/calendar" {
            return Data("[{\"weekday\":{\"id\":1},\"items\":[\(subject)]},{\"weekday\":{\"id\":2},\"items\":[\(tuesday)]}]".utf8)
        }
        if url.path == "/v0/search/subjects" {
            return Data("{\"total\":2,\"data\":[\(subject),\(tuesday)]}".utf8)
        }
        if url.path == "/v0/subjects/4242" { return Data(subject.utf8) }
        if url.path == "/v0/subjects/4243" { return Data(tuesday.utf8) }
        if url.path == "/v0/episodes" {
            return Data(#"{"total":2,"data":[{"id":4201,"type":0,"sort":1,"ep":1,"name":"Not available in source","airdate":"2020-01-01"},{"id":4202,"type":0,"sort":2,"ep":2,"name":"Playable episode","airdate":"2020-01-02"}]}"#.utf8)
        }
        return nil
    }
    static func playerURL(_ url: URL) -> URL {
        guard enabled, url == mediaURL else { return url }
        return Bundle.main.url(forResource: "player-fixture-01", withExtension: "mp4") ?? url
    }
}

actor SourceFixtureTransport {
    private var resolutions = 0
    func fetch(_ url: URL) async throws -> Data {
        try await Task.sleep(for: .milliseconds(150))
        if ProcessInfo.processInfo.arguments.contains("-native-playback-ui-fixture") {
            guard url.host == "www.jibi.cc" else { throw MobileSourceError.invalidSelection }
            if url.path == "/index.php/vod/detail/id/42.html" {
                return Data("""
                <div class="module-info-heading"><h1>Native Jibi Playback Fixture</h1></div>
                <div class="module-tab-item" data-dropdown-value="Fixture native line"></div>
                <div class="module-play-list">
                <a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/7/nid/2.html">Episode 2</a>
                <a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/7/nid/3.html">Episode 3</a>
                </div>
                """.utf8)
            }
            guard let number = [2, 3].first(where: { url.path == "/index.php/vod/play/id/42/sid/7/nid/\($0).html" }) else {
                throw MobileSourceError.invalidSelection
            }
            let payload: [String: Any] = ["id": "42", "sid": 7, "nid": number, "points": 0, "trysee": 0, "encrypt": 0,
                "url": SourceFixtures.mediaURL.absoluteString]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            return Data("<script>var player_aaaa=\(json);</script>".utf8)
        }
        if url.path.contains("search") {
            return Data("<div class='module-card-item-info'><div class='module-card-item-title'><a href='/index.php/vod/detail/id/42.html'>Source Flow Fixture</a></div></div>".utf8)
        }
        if url.path.contains("detail") {
            return Data("<div class='module-info-heading'><h1>Source Flow Fixture</h1></div><div class='module-tab-item tab-item'><span>Fixture line</span></div><div class='module-play-list'><a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/1/nid/2.html'>Episode 2</a><a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/1/nid/3.html'>Episode 3</a><a class='module-play-list-link' href='/index.php/vod/play/id/42/sid/1/nid/4.html'>Episode 4</a></div>".utf8)
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-source-ui-diagnostic"), arguments.indices.contains(index + 1),
           let failure = PlaybackFailure(rawValue: arguments[index + 1]),
           [PlaybackFailure.unsupportedEncryption, .httpForbidden, .playerServiceUnavailable].contains(failure) { throw failure }
        resolutions += 1
        let wrong = ProcessInfo.processInfo.arguments.contains("-source-ui-failure") && resolutions == 1
        let components = url.pathComponents
        let selected = components.firstIndex(of: "nid").flatMap {
            components.indices.contains($0 + 1) ? Int(components[$0 + 1].split(separator: ".").first ?? "") : nil
        } ?? 2
        let payload: [String: Any] = ["id": "42", "sid": 1, "nid": wrong ? 1 : selected, "points": 0, "trysee": 0, "encrypt": 0, "url": SourceFixtures.mediaURL.absoluteString]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return Data("<script>var player_aaaa=\(json);</script>".utf8)
    }
}
#endif
