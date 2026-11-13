import Foundation
import XCTest
import SourceCore
@testable import SourceRuntime

final class ConfiguredSourceClientTests: XCTestCase {
    private static let origin = "https://catalog.example.com"
    private static let detail = origin + "/detail/42.html"
    private static let catalogURL = origin + "/api/catalog/42/index.json"
    private static let episodeURL = origin + "/watch/42-2-7.html"
    private static let playerURL = origin + "/api/player/42/7.json"
    private static let media = "https://media.example.org/42-7.mp4"

    private struct Reply: Sendable {
        let data: Data
        let status: Int
        init(_ data: Data, status: Int = 200) { self.data = data; self.status = status }
    }

    private func configuration(version: Int = 1, capabilities: [String] = ["information", "episodes", "lines", "resolve", "mpv"],
                               catalog: [String: Any]? = nil,
                               route: [String: Any]? = nil, player: [String: Any]? = nil) throws -> SourceConfiguration {
        let object: [String: Any] = [
            "id": "configured-fixture", "name": "Configured fixture", "version": version,
            "hosts": ["catalog.example.com"], "mediaHosts": ["media.example.org"],
            "capabilities": capabilities,
            "route": route ?? ["pattern": "^/(?:detail/|watch/)([A-Za-z0-9_]+)(?:-([0-9]+)-([0-9]+))?\\.html$",
                "idGroup": 1, "lineGroup": 2, "episodeGroup": 3, "detailTemplate": Self.origin + "/detail/{id}.html"],
            "catalog": catalog ?? ["url": Self.origin + "/api/catalog/{id}/index.json", "format": "json",
                "jsonTitlePath": "title", "jsonEntriesPath": "episodes", "jsonEpisodeTitlePath": "title",
                "jsonEpisodeURLPath": "page", "jsonMediaPath": "player"],
            "player": player ?? ["format": "json", "payloadPattern": "player", "idKey": "id", "idIsString": true,
                "lineKey": "line", "episodeKey": "episode", "paidKey": "paid", "previewKey": "preview",
                "encodingKey": "encoding", "urlKey": "url", "allowedExtensions": ["mp4"]]
        ]
        return try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object))
    }

    private func catalogData(_ entries: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["title": "Fixture work", "episodes": entries])
    }

    private func playerData(line: Int = 2, episode: Int = 7, id: String = "42") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["player": ["id": id, "line": line, "episode": episode,
            "paid": 0, "preview": 0, "encoding": 0, "url": Self.media]])
    }

    private func client(_ configuration: SourceConfiguration, replies: [String: Reply]) -> ConfiguredSourceClient {
        ConfiguredSourceClient(configuration: configuration, fetch: { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            let url = try XCTUnwrap(request.url)
            guard let reply = replies[url.absoluteString] else {
                XCTFail("Unexpected configured-source request: \(url.path)")
                throw PlaybackFailure.network
            }
            return SourceHTTPResponse(data: reply.data, url: url, statusCode: reply.status)
        })
    }

    private func work(_ configuration: SourceConfiguration, page: String = ConfiguredSourceClientTests.detail) throws -> RuntimeWork {
        RuntimeWork(item: try configuration.item(page), title: "Fixture work")
    }

    private func assertFailure(_ expected: PlaybackFailure, file: StaticString = #filePath, line: UInt = #line,
                               _ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? PlaybackFailure, expected, file: file, line: line) }
    }

    func testSeparateAbsoluteAndRelativePlayerPathsKeepExactURLDerivedEpisode() async throws {
        for version in [1, 2] {
            for (page, player) in [(Self.episodeURL, Self.playerURL),
                                   ("../../../watch/42-2-7.html", "../../player/42/7.json")] {
                let configuration = try configuration(version: version)
                let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([
                    ["title": "Episode 7", "page": page, "player": player],
                    ["title": "Episode 8", "page": "/watch/42-2-8.html", "player": "/api/player/42/8.json"]
                ])), Self.playerURL: Reply(try playerData())])
                let catalog = try await instance.catalog(work(configuration))
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                XCTAssertEqual(catalog.lines.map(\.id), [2])
                XCTAssertEqual(selected.item.pageURL, Self.episodeURL)
                XCTAssertEqual(selected.line, 2)
                XCTAssertEqual(selected.number, 7)
                XCTAssertEqual(selected.identity, "7")
                XCTAssertEqual(selected.mediaPath, Self.playerURL)
                let resolved = try await instance.resolve(selected, in: catalog)
                XCTAssertEqual(resolved.absoluteString, Self.media)
                let forged = RuntimeEpisode(item: selected.item, title: selected.title, line: 2, number: 8,
                    identity: "8", mediaPath: selected.mediaPath)
                await assertFailure(.missingEpisode) { _ = try await instance.resolve(forged, in: catalog) }
            }
        }
    }

    func testQueryFileIdentityPreservesWorkQueryAndStreamTemplatePath() async throws {
        let configuration = try configuration(capabilities: ["information", "episodes", "resolve", "mpv"],
            catalog: ["url": Self.origin + "/api/catalog/{id}/index.json", "format": "json",
            "jsonTitlePath": "title", "jsonEntriesPath": "episodes", "jsonEpisodeTitlePath": "title",
            "jsonEpisodeIdentityPath": "file", "jsonMediaPath": "file", "jsonEntryExtensions": ["mp4"]],
            route: ["pattern": "^/detail/([A-Za-z0-9_]+)\\.html$", "idGroup": 1,
                "detailTemplate": Self.origin + "/detail/{id}.html", "queryIdentityParameter": "file"],
            player: ["format": "json", "allowedExtensions": ["mp4"],
                "streamURLTemplate": "https://media.example.org/download/{id}/{file}"])
        let filename = "Season 2/第07集 + final.mp4"
        let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([
            ["title": "Ignored text", "file": "notes.txt"], ["title": "Episode 7", "file": filename]
        ]))])
        let catalog = try await instance.catalog(work(configuration, page: Self.detail + "?season=2"))
        let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
        XCTAssertEqual(selected.line, 1)
        XCTAssertEqual(selected.number, 2)
        XCTAssertEqual(selected.identity, filename)
        let components = try XCTUnwrap(URLComponents(string: selected.item.pageURL))
        XCTAssertEqual(components.path, "/detail/42.html")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "season", value: "2"), URLQueryItem(name: "file", value: filename)])
        let resolved = try await instance.resolve(selected, in: catalog)
        XCTAssertEqual(resolved.absoluteString, configuration.expanded("https://media.example.org/download/{id}/{file}",
            values: ["id": "42", "file": filename]))
    }

    func testDeclaredNumberingRejectsMissingInvalidAndMismatchedValues() async throws {
        let configuration = try configuration(catalog: ["url": Self.origin + "/api/catalog/{id}/index.json", "format": "json",
            "jsonTitlePath": "title", "jsonEntriesPath": "episodes", "jsonEpisodeTitlePath": "title",
            "jsonEpisodeURLPath": "page", "jsonMediaPath": "player", "jsonLineNumberPath": "line", "jsonEpisodeNumberPath": "number"])
        let base: [String: Any] = ["title": "Episode 7", "page": Self.episodeURL, "player": Self.playerURL]
        let invalidNumbering: [[String: Any]] = [["line": 2], ["number": 7], ["line": "2", "number": 7],
            ["line": 2, "number": "7"], ["line": 1, "number": 7], ["line": 2, "number": 8],
            ["line": 0, "number": 7], ["line": 2, "number": -1], ["line": 2, "number": 7.5]]
        for numbering in invalidNumbering {
            let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([base.merging(numbering) { _, new in new }]))])
            await assertFailure(.mediaNotFound) { _ = try await instance.catalog(work(configuration)) }
        }
        let valid = base.merging(["line": 2, "number": 7]) { _, new in new }
        let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([valid])),
            Self.playerURL: Reply(try playerData())])
        let catalog = try await instance.catalog(work(configuration))
        let resolved = try await instance.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog)
        XCTAssertEqual(resolved.absoluteString, Self.media)
    }

    func testCatalogRejectsForeignWorkAndMissingRouteCaptures() async throws {
        let configuration = try configuration()
        for page in ["/watch/99-2-7.html", "/detail/42.html", "https://untrusted.example.com/watch/42-2-7.html"] {
            let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([
                ["title": "Wrong episode", "page": page, "player": Self.playerURL]
            ]))])
            await assertFailure(.mediaNotFound) { _ = try await instance.catalog(work(configuration)) }
        }
        let queryConfiguration = try self.configuration(catalog: ["url": Self.origin + "/api/catalog/{id}/index.json", "format": "json",
            "jsonTitlePath": "title", "jsonEntriesPath": "episodes", "jsonEpisodeTitlePath": "title", "jsonEpisodeIdentityPath": "file"],
            route: ["pattern": "^/(?:detail/|watch/)([A-Za-z0-9_]+)(?:-([0-9]+)-([0-9]+))?\\.html$", "idGroup": 1,
                "lineGroup": 2, "episodeGroup": 3, "detailTemplate": Self.origin + "/detail/{id}.html", "queryIdentityParameter": "file"])
        let instance = client(queryConfiguration, replies: [Self.catalogURL: Reply(try catalogData([["title": "Episode", "file": "7.mp4"]]))])
        await assertFailure(.mediaNotFound) { _ = try await instance.catalog(work(queryConfiguration)) }
    }

    func testPlayerCannotResolveDifferentEpisodeOrWork() async throws {
        let configuration = try configuration()
        for payload in [try playerData(episode: 8), try playerData(line: 1), try playerData(id: "99")] {
            let instance = client(configuration, replies: [Self.catalogURL: Reply(try catalogData([
                ["title": "Episode 7", "page": Self.episodeURL, "player": Self.playerURL]
            ])), Self.playerURL: Reply(payload)])
            let catalog = try await instance.catalog(work(configuration))
            await assertFailure(.mediaNotFound) {
                _ = try await instance.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog)
            }
        }
    }

    func testHTMLOmittedEpisodeTitleSelectorUsesLinkTextAndResolvesMedia() async throws {
        let configuration = try configuration(catalog: ["url": Self.origin + "/detail/{id}.html", "format": "html",
            "titleSelector": "h1", "panelSelector": ".episodes", "episodeSelector": "a", "episodeURLAttribute": "href"])
        let html = "<h1>Fixture work</h1><ul class='episodes'><li><a href='/watch/42-2-7.html'>Episode <b>7</b></a></li></ul>"
        let instance = client(configuration, replies: [Self.detail: Reply(Data(html.utf8)), Self.episodeURL: Reply(try playerData())])
        let catalog = try await instance.catalog(work(configuration))
        let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
        XCTAssertEqual(selected.title, "Episode 7")
        XCTAssertEqual(selected.item.pageURL, Self.episodeURL)
        let resolved = try await instance.resolve(selected, in: catalog)
        XCTAssertEqual(resolved.absoluteString, Self.media)
    }

    func testHTTPFailureCategoriesAtCatalogAndPlayerBoundaries() async throws {
        let configuration = try configuration()
        let validCatalog = try catalogData([["title": "Episode 7", "page": Self.episodeURL, "player": Self.playerURL]])
        let statuses: [(Int, PlaybackFailure)] = [(401, .authenticationRequired), (403, .httpForbidden),
            (301, .sourceRedirect), (302, .sourceRedirect), (399, .sourceRedirect), (408, .network), (429, .network),
            (500, .network), (503, .network), (599, .network), (404, .mediaNotFound), (410, .mediaNotFound),
            (400, .unsupportedResponse), (418, .unsupportedResponse)]
        for (status, expected) in statuses {
            let catalogFailure = client(configuration, replies: [Self.catalogURL: Reply(Data(), status: status)])
            await assertFailure(expected) { _ = try await catalogFailure.catalog(work(configuration)) }
            let playerFailure = client(configuration, replies: [Self.catalogURL: Reply(validCatalog),
                Self.playerURL: Reply(Data(), status: status)])
            let catalog = try await playerFailure.catalog(work(configuration))
            await assertFailure(expected) {
                _ = try await playerFailure.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog)
            }
        }
    }

    func testOversizedBodiesAndTransportErrorsKeepFailureCategoryAtBothBoundaries() async throws {
        let configuration = try configuration()
        let validCatalog = try catalogData([["title": "Episode 7", "page": Self.episodeURL, "player": Self.playerURL]])
        let oversized = Data(repeating: 0, count: SourceHTTPTransport.maximumResponseBytes + 1)
        for playerBoundary in [false, true] {
            let bodyFailure = client(configuration, replies: [Self.catalogURL: Reply(playerBoundary ? validCatalog : oversized),
                Self.playerURL: Reply(oversized)])
            let transportFailure = ConfiguredSourceClient(configuration: configuration, fetch: { request in
                let url = try XCTUnwrap(request.url)
                if playerBoundary && url.absoluteString == Self.catalogURL {
                    return SourceHTTPResponse(data: validCatalog, url: url, statusCode: 200)
                }
                throw SourceHTTPTransportError.oversizedResponse
            })
            for instance in [bodyFailure, transportFailure] {
                await assertFailure(.invalidResponseBody) {
                    let catalog = try await instance.catalog(work(configuration))
                    if playerBoundary {
                        _ = try await instance.resolve(try XCTUnwrap(catalog.lines.first?.episodes.first), in: catalog)
                    }
                }
            }
        }
    }
}
