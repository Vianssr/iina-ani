import Foundation
import XCTest
import SourceCore
@testable import SourceRuntime

final class StaticWebSourceTests: XCTestCase {
    private static let origin = "https://catalog.example.com"
    private static let detail = origin + "/series/42?season=2"
    private static let episode = origin + "/vodplay/42-2-7.html"
    private static let media = "https://media.example.org/show-42-7.mp4"

    private struct Reply: Sendable {
        let data: Data
        let status: Int
        let finalURL: URL?
        init(_ text: String, status: Int = 200, finalURL: String? = nil) {
            data = Data(text.utf8); self.status = status; self.finalURL = finalURL.flatMap(URL.init(string:))
        }
    }

    private func configuration(version: Int = 4, height: Int? = nil, separateNames: Bool = false) throws -> SourceConfiguration {
        var selector: [String: Any] = ["baseURL": Self.origin, "subjectFormat": "a",
            "searchNames": ".result", "searchLinks": ".result", "channelFormat": "index-grouped",
            "channelNames": ".line-name", "episodeLists": ".episodes",
            "episodeNames": separateNames ? ".episode-name" : "a.episode-link",
            "episodeLinks": "a.episode-link"]
        if let height { selector["preferredVideoHeight"] = height }
        let search: [String: Any] = version == 3
            ? ["url": Self.origin + "/search?q={query}", "format": "web-selector", "queryParameter": "", "pageParameter": "", "rowsPerPage": 100]
            : ["url": Self.origin + "/search?q={query}", "format": "html", "queryParameter": "q", "pageParameter": "page", "rowsPerPage": 20,
               "resultsSelector": ".result", "titleSelector": "self", "hrefAttribute": "href"]
        let object: [String: Any] = ["id": "static-example", "name": "Example static source", "version": version,
            "hosts": ["catalog.example.com"], "mediaHosts": ["media.example.org"],
            "anonymousExternalHTTPSMedia": false,
            "capabilities": ["information", "search", "episodes", "lines", "resolve", "mpv"],
            "route": ["pattern": "^/(.*)$", "idGroup": 1, "detailTemplate": Self.origin + "/{id}"],
            "catalog": ["url": Self.origin + "/{id}", "format": "web-selector"],
            "player": ["format": "web-selector", "allowedExtensions": ["mp4", "m3u8"]],
            "search": search, "webSelector": selector]
        return try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object))
    }

    private static let catalogHTML = """
        <div class='line-name'>Line B</div><ul class='episodes'>
        <li><a class='episode-link' href='/vodplay/42-2-7.html'>第07集</a></li>
        <li><a class='episode-link' href='/vodplay/42-2-8.html'>第08集</a></li></ul>
        """

    private func client(_ configuration: SourceConfiguration, replies: [String: Reply]) -> StaticWebSourceClient {
        StaticWebSourceClient(configuration: configuration, fetch: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            let url = try XCTUnwrap(request.url)
            guard let reply = replies[url.absoluteString] else { throw PlaybackFailure.network }
            return SourceHTTPResponse(data: reply.data, url: reply.finalURL ?? url, statusCode: reply.status)
        })
    }

    private func work(_ configuration: SourceConfiguration) throws -> RuntimeWork {
        RuntimeWork(item: try configuration.webItem(Self.detail, kind: .work), title: "Example season 2")
    }

    private func assertFailure(_ expected: PlaybackFailure, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PlaybackFailure, expected, file: file, line: line) }
    }

    func testNewHostSearchCatalogAndExactEpisodeResolve() async throws {
        let configuration = try configuration()
        let search = try SourceSearchExecutor.requestURL(try XCTUnwrap(configuration.search), query: "Fixture", page: 1,
            allowedHosts: configuration.requestHosts)
        let instance = client(configuration, replies: [
            search.absoluteString: Reply("<a class='result' href='/series/42?season=2'>Example season 2</a>"),
            Self.detail: Reply(Self.catalogHTML), Self.episode: Reply("<video src='\(Self.media)'></video>")])
        let found = try await instance.search(query: "Fixture")
        XCTAssertEqual(found.results.count, 1)
        XCTAssertEqual(found.results.first?.item.pageURL, Self.detail)
        let catalog = try await instance.catalog(work(configuration))
        let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
        XCTAssertEqual(selected.item.pageURL, Self.episode)
        XCTAssertEqual(selected.identity, Self.episode)
        XCTAssertEqual(selected.number, 7)
        let resolved = try await instance.resolve(selected, in: catalog)
        XCTAssertEqual(resolved.absoluteString, Self.media)
        let forged = RuntimeEpisode(item: selected.item, title: selected.title, line: 2, number: selected.number,
                                    identity: selected.identity)
        await assertFailure(.missingEpisode) { _ = try await instance.resolve(forged, in: catalog) }
    }

    func testSearchOverlayRetainsConfiguredTransportAndIdentity() async throws {
        let configuration = try configuration()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(configuration.search))) as! [String: Any]
        object["url"] = Self.origin + "/updated-search?term={query}"
        object["queryParameter"] = "term"
        object["resultsSelector"] = "a.updated-result"
        let overlay = try JSONDecoder().decode(SourceConfiguration.Search.self, from: JSONSerialization.data(withJSONObject: object))
        let request = try SourceSearchExecutor.requestURL(overlay, query: "Fixture", page: 1,
            allowedHosts: configuration.requestHosts)
        let instance = client(configuration, replies: [request.absoluteString: Reply("""
            <a class='result' href='/series/wrong'>Original selector decoy</a>
            <a class='updated-result' href='/series/42?season=2'>Updated fixture</a>
            """)])
        let found = try await instance.search(query: "Fixture", searchOverride: overlay)
        XCTAssertEqual(found.results.count, 1)
        XCTAssertEqual(found.results.first?.title, "Updated fixture")
        XCTAssertEqual(found.results.first?.item, try configuration.webItem(Self.detail, kind: .work))
        await assertFailure(.searchStructure) {
            _ = try await instance.search(query: String(repeating: "x", count: 1025), searchOverride: overlay)
        }
        let redirected = client(configuration, replies: [request.absoluteString:
            Reply("<a class='updated-result' href='/series/42?season=2'>Fixture</a>",
                  finalURL: "https://elsewhere.example.org/search")])
        do {
            _ = try await redirected.search(query: "Fixture", searchOverride: overlay)
            XCTFail("Overlay search accepted a cross-host redirect")
        } catch {}
        let oversized = client(configuration, replies: [request.absoluteString:
            Reply(String(repeating: "x", count: 4 * 1024 * 1024 + 1))])
        do {
            _ = try await oversized.search(query: "Fixture", searchOverride: overlay)
            XCTFail("Overlay search accepted an oversized response")
        } catch {}
    }

    func testSearchOverlayCannotExpandHostOrCredentialBoundaries() async throws {
        let configuration = try configuration()
        let instance = StaticWebSourceClient(configuration: configuration, fetch: { _ in
            XCTFail("Unsafe search overlay must be rejected before fetching")
            throw PlaybackFailure.network
        })
        for url in ["https://elsewhere.example.org/search?q={query}",
                    "https://user:password@catalog.example.com/search?q={query}",
                    Self.origin + "/search?q={query}&token=secret"] {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(configuration.search))) as! [String: Any]
            object["url"] = url
            let overlay = try JSONDecoder().decode(SourceConfiguration.Search.self, from: JSONSerialization.data(withJSONObject: object))
            do {
                _ = try await instance.search(query: "Fixture", searchOverride: overlay)
                XCTFail("Unsafe overlay search was accepted")
            } catch { XCTAssertTrue(error is SourceSearchError) }
        }
    }

    func testSiblingLabelsDoNotShiftAcrossMissingLinks() async throws {
        let configuration = try configuration(separateNames: true)
        let html = """
            <ul class='episodes'><li><span class='episode-name'>第07集</span><a class='episode-link' href='/vodplay/42-2-7.html'>Play</a></li>
            <li><span class='episode-name'>第08集</span></li>
            <li><span class='episode-name'>第09集</span><a class='episode-link' href='/vodplay/42-2-9.html'>Play</a></li></ul>
            """
        let instance = client(configuration, replies: [Self.detail: Reply(html)])
        await assertFailure(.catalogStructure) { _ = try await instance.catalog(work(configuration)) }
    }

    func testSearchAndCatalogKeepOriginAndStatusBoundaries() async throws {
        let configuration = try configuration()
        for (status, expected) in [(401, PlaybackFailure.authenticationRequired), (403, .httpForbidden),
                                   (404, .mediaNotFound), (503, .unsupportedResponse)] {
            let instance = client(configuration, replies: [Self.detail: Reply("response", status: status)])
            await assertFailure(expected) { _ = try await instance.catalog(work(configuration)) }
        }
        for target in [Self.origin + "/series/other", "https://elsewhere.example.org/series/42"] {
            let instance = client(configuration, replies: [Self.detail: Reply(Self.catalogHTML, finalURL: target)])
            await assertFailure(.sourceRedirect) { _ = try await instance.catalog(work(configuration)) }
        }
        let challenge = client(configuration, replies: [Self.detail: Reply("<form id='challenge-form'></form>")])
        await assertFailure(.websiteVerification) { _ = try await challenge.catalog(work(configuration)) }
        let oversized = client(configuration, replies: [Self.detail: Reply(String(repeating: "x", count: 4 * 1024 * 1024 + 1))])
        await assertFailure(.invalidResponseBody) { _ = try await oversized.catalog(work(configuration)) }
    }

    private func player(encoding: Int = 0, episode: Int = 7, points: Int = 0) throws -> String {
        let escaped = Self.media.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let encoded = encoding == 1 ? escaped : encoding == 2 ? Data(escaped.utf8).base64EncodedString() : Self.media
        let payload: [String: Any] = ["id": "42", "sid": 2, "nid": episode, "encrypt": encoding,
            "points": points, "trysee": 0, "url": encoded, "ad": ["text": "braces } in nested metadata"]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        return "<script>var player_aaaa=\(json);</script>"
    }

    func testStaticMacCMSDecodesOnlySupportedPublicPayloads() async throws {
        let configuration = try configuration()
        for encoding in [0, 1, 2] {
            let instance = client(configuration, replies: [Self.detail: Reply(Self.catalogHTML),
                Self.episode: Reply(try player(encoding: encoding))])
            let catalog = try await instance.catalog(work(configuration))
            let resolved = try await instance.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog)
            XCTAssertEqual(resolved.absoluteString, Self.media)
        }
        for (html, expected) in [(try player(encoding: 3), PlaybackFailure.unsupportedEncryption),
                                 (try player(episode: 8), .missingEpisode), (try player(points: 1), .authenticationRequired),
                                 ("<iframe src='https://parser.example.org/player'></iframe>", .indirectMedia),
                                 ("<video src='\(Self.media)'></video><video src='https://media.example.org/other.mp4'></video>", .ambiguousMedia)] {
            let instance = client(configuration, replies: [Self.detail: Reply(Self.catalogHTML), Self.episode: Reply(html)])
            let catalog = try await instance.catalog(work(configuration))
            await assertFailure(expected) { _ = try await instance.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog) }
        }
    }

    func testPreferredQualityNeverFallsBackAndV3RemainsInactive() async throws {
        let html = "<video><source size='720' src='https://media.example.org/720.mp4'><source size='1080' src='\(Self.media)'></video>"
        for height in [1080, 2160] {
            let configuration = try configuration(height: height)
            let instance = client(configuration, replies: [Self.detail: Reply(Self.catalogHTML), Self.episode: Reply(html)])
            let catalog = try await instance.catalog(work(configuration))
            let episode = try XCTUnwrap(catalog.lines.first?.episodes.first)
            if height == 1080 {
                let resolved = try await instance.resolve(episode, in: catalog)
                XCTAssertEqual(resolved.absoluteString, Self.media)
            } else { await assertFailure(.missingMediaQuality) { _ = try await instance.resolve(episode, in: catalog) } }
        }
        let legacy = try configuration(version: 3)
        do {
            _ = try await client(legacy, replies: [:]).catalog(work(legacy))
            XCTFail("v3 must remain inactive")
        } catch { XCTAssertEqual(error as? SourceConfiguration.ConfigurationError, .unsupportedCapability) }
    }
}
