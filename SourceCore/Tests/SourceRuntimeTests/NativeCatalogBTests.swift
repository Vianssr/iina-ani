import Foundation
import XCTest
import SourceCore
@testable import SourceRuntime

final class NativeCatalogBTests: XCTestCase {
    private struct Fixture: Sendable {
        let id: String
        let detail: String
        let episode: String
        let html: String
        let lineTitle: String
        let line: Int
    }

    private static let fixtures: [Fixture] = [
        Fixture(id: "wedm", detail: "https://www.vdm5.com/vodetail_show-id.html",
                episode: "https://www.vdm5.com/dmplay_show-id-2-7.html",
                html: """
                <h1 class="title">Fixture</h1><section class="stui-pannel"><h3 class="title">Web</h3>
                <ul class="stui-content__playlist"><li><a href="/dmplay_show-id-2-7.html">Episode 7</a></li>
                <li><a href="/dmplay_show-id-2-7.html">Duplicate</a></li>
                <li><a href="/dmplay_other-2-7.html">Other work</a></li>
                <li><a href="https://www.mutedm.com/vodplay/42-2-7.html">Other source</a></li></ul></section>
                """, lineTitle: "Web", line: 2),
        Fixture(id: "fengche", detail: "https://www.dongmandaquan.vip/voddetail/42.html",
                episode: "https://www.dongmandaquan.vip/vodplay/42-2-7.html",
                html: """
                <div class="detail-info-title"><h1>Fixture</h1></div>
                <div class="ewave-playlist-tab"><a data-target="#ewave-playlist-2">Web</a></div>
                <div id="ewave-playlist-2"><a href="/vodplay/42-2-7.html">Episode 7</a>
                <a href="/vodplay/42-2-7.html">Duplicate</a><a href="/vodplay/99-2-7.html">Other work</a>
                <a href="https://www.mutedm.com/vodplay/42-2-7.html">Other source</a></div>
                """, lineTitle: "Web", line: 2),
        Fixture(id: "mutedm", detail: "https://www.mutedm.com/voddetail/42.html",
                episode: "https://www.mutedm.com/vodplay/42-3-7.html",
                html: """
                <h1>Fixture</h1><div class="module-tab-item" data-dropdown-value="Web"></div>
                <div class="module-play-list-content"><a href="/vodplay/42-3-7.html">Episode 7</a></div>
                """, lineTitle: "Web", line: 3),
        Fixture(id: "rebo", detail: "https://www.rebozj.cc/detail/42.html",
                episode: "https://www.rebozj.cc/play/42-2-7.html",
                html: """
                <div class="stui-content__detail"><h1 class="title">Fixture</h1></div>
                <ul class="nav-tabs"><li><a href="#playlist0">Web</a></li><li><a href="#playlist1">Unsupported</a></li></ul>
                <div id="playlist0"><ul class="stui-content__playlist"><li><a href="/play/42-2-7.html">Episode 7</a></li>
                <li><a href="/play/42-2-7.html">Duplicate</a></li><li><a href="/play/99-2-7.html">Other work</a></li></ul></div>
                <div id="playlist1"><ul class="stui-content__playlist"><li><a href="/play/42-4-7.html">App</a></li></ul></div>
                """, lineTitle: "Web", line: 2)
    ]

    private static func player(_ fixture: Fixture, overrides: [String: String] = [:]) -> String {
        var fields = ["id": fixture.id == "wedm" ? "\"show-id\"" : "\"42\"",
                      "sid": String(fixture.line), "nid": "7", "points": "0", "trysee": "0",
                      "encrypt": fixture.id == "mutedm" || fixture.id == "rebo" ? "3" : "2",
                      "from": fixture.id == "mutedm" ? "\"m2\"" : "\"BBA\"",
                      "url": fixture.id == "rebo" ? "\"aabb\"" : fixture.id == "mutedm" ? "\"episode-token\"" : "\"\(Data("https%3A%2F%2Fmedia.example%2Fvideo.mp4".utf8).base64EncodedString())\""]
        fields.merge(overrides) { _, new in new }
        return "<script>var player_aaaa={" + fields.sorted { $0.key < $1.key }.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "};</script>"
    }

    private static func client(_ fixture: Fixture, overrides: [String: String] = [:]) -> NativeSourceClient {
        NativeSourceClient(sourceID: fixture.id, fetch: { request in
            let url = try XCTUnwrap(request.url)
            let body: String
            switch url.absoluteString {
            case fixture.detail: body = fixture.html
            case fixture.episode: body = player(fixture, overrides: overrides)
            case "https://www.rebozj.cc/play/42-4-7.html": body = player(fixture, overrides: ["sid": "4", "encrypt": "9"])
            default:
                if url.host == "www.mutedm.com", url.path == "/addons/dp/player/index.php" {
                    let fields = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                    XCTAssertEqual(fields.first { $0.name == "id" }?.value, "42")
                    XCTAssertEqual(fields.first { $0.name == "url" }?.value, "episode-token")
                    body = #"window.location.href="/addons/dp/player/dp.php?id=42&from=m2&url=episode-token";"#
                } else if url.host == "www.mutedm.com", url.path == "/addons/dp/player/dp.php" {
                    body = #"var config={"api_vod_url":"episode-token","url":"https://media.example/video.mp4"};"#
                } else if url.absoluteString == "https://www.rebozj.cc/static/player/BBA.js" {
                    body = #"var parser="/static/player/artplayer/?url=";"#
                } else if url.host == "www.rebozj.cc", URLComponents(url: url, resolvingAgainstBaseURL: false)?.path == "/static/player/artplayer/" {
                    XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "url", value: "aabb")])
                    body = #"const timestamp="1700000000"; const qualities=[{"url":"Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M="}];"#
                } else {
                    XCTFail("Unexpected fixture request: \(url)")
                    throw PlaybackFailure.invalidResponseBody
                }
            }
            return SourceHTTPResponse(data: Data(body.utf8), url: url, statusCode: 200)
        })
    }

    func testExactCatalogLeavesAndResolutionForEverySource() async throws {
        for fixture in Self.fixtures {
            let source = RuntimeSource.native(fixture.id)
            let work = RuntimeWork(item: try source.item(fixture.detail), title: "Fixture")
            let client = Self.client(fixture)
            let catalog = try await client.catalog(work)
            XCTAssertEqual(catalog.work.item, work.item, fixture.id)
            XCTAssertEqual(catalog.work.title, "Fixture", fixture.id)
            XCTAssertEqual(catalog.lines.map(\.title), [fixture.lineTitle], fixture.id)
            XCTAssertEqual(catalog.lines.map(\.id), [fixture.line], fixture.id)
            let episodes = catalog.lines.flatMap(\.episodes)
            XCTAssertEqual(episodes.map(\.title), ["Episode 7"], fixture.id)
            XCTAssertEqual(episodes.map(\.item.pageURL), [fixture.episode], fixture.id)
            XCTAssertEqual(episodes.map(\.item.sourceID), [fixture.id], fixture.id)
            XCTAssertEqual(episodes.map(\.line), [fixture.line], fixture.id)
            XCTAssertEqual(episodes.map(\.number), [7], fixture.id)
            XCTAssertEqual(episodes.map(\.identity), ["\(fixture.id):\(fixture.id == "wedm" ? "show-id" : "42"):7"], fixture.id)
            let quality = fixture.id == "mutedm" ? "Line \(fixture.line)" : "\(fixture.lineTitle) (\(fixture.line))"
            XCTAssertEqual(episodes.map(\.qualityID), [quality], fixture.id)
            let selected = try XCTUnwrap(episodes.first)
            let media = try await client.resolve(selected, in: catalog)
            XCTAssertEqual(media.absoluteString, "https://media.example/video.mp4", fixture.id)
        }
    }

    func testPlayerIdentityPaidAndEncryptionRejections() async throws {
        for fixture in Self.fixtures {
            let work = RuntimeWork(item: try RuntimeSource.native(fixture.id).item(fixture.detail), title: "Fixture")
            let goodCatalog = try await Self.client(fixture).catalog(work)
            let selected = try XCTUnwrap(goodCatalog.lines.first?.episodes.first)
            for overrides in [["nid": "8"], ["id": "\"99\""], ["points": "1"], ["trysee": "1"], ["encrypt": "99"]] {
                do {
                    _ = try await Self.client(fixture, overrides: overrides).resolve(selected, in: goodCatalog)
                    XCTFail("Accepted invalid player for \(fixture.id): \(overrides)")
                } catch { XCTAssertTrue(error is PlaybackFailure, "\(fixture.id): \(error)") }
            }
        }
    }

    func testMutedmAppOnlyHasExplicitFailure() async throws {
        let fixture = Self.fixtures[2]
        let good = Self.client(fixture)
        let work = RuntimeWork(item: try RuntimeSource.native(fixture.id).item(fixture.detail), title: "Fixture")
        let catalog = try await good.catalog(work)
        let episode = try XCTUnwrap(catalog.lines.first?.episodes.first)
        do {
            _ = try await Self.client(fixture, overrides: ["from": "\"r2\""]).resolve(episode, in: catalog)
            XCTFail("App-only player was accepted")
        } catch let error as PlaybackFailure {
            XCTAssertEqual(error, .appOnlyPlayback)
        }
    }

    func testForeignAndUnlistedEpisodeSelectionsAreRejected() async throws {
        for fixture in Self.fixtures {
            let source = RuntimeSource.native(fixture.id)
            let work = RuntimeWork(item: try source.item(fixture.detail), title: "Fixture")
            let client = Self.client(fixture)
            let catalog = try await client.catalog(work)
            let original = try XCTUnwrap(catalog.lines.first?.episodes.first)
            for item in [SourceItemRef(sourceID: "foreign", pageURL: fixture.episode, kind: .episode),
                         try source.item(fixture.episode.replacingOccurrences(of: "-7.html", with: "-8.html"))] {
                let foreign = RuntimeEpisode(item: item, title: original.title, line: original.line,
                                             number: original.number, identity: original.identity,
                                             mediaPath: original.mediaPath, qualityID: original.qualityID)
                do {
                    _ = try await client.resolve(foreign, in: catalog)
                    XCTFail("Accepted foreign or unlisted selection for \(fixture.id)")
                } catch { XCTAssertTrue(error is PlaybackFailure) }
            }
        }
    }
}
