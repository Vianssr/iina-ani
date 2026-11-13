import Foundation
import XCTest
import SourceCore
@testable import SourceRuntime

final class NativeCatalogATests: XCTestCase {
    func testGirigiriCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.girigiri) }
    func testJibiCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.jibi) }
    func testEACGCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.eacg) }
    func testKanbaCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.kanba) }
    func testSenfunCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.senfun) }
    func testYinghuaCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.yinghua) }
    func testDilidiliCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.dilidili) }
    func testYouknowCatalogAndEveryLeafResolve() async throws { try await assertFixture(Self.youknow) }

    func testCatalogAuthenticationAndForbiddenResponsesForEverySource() async throws {
        for fixture in Self.fixtures {
            for (status, expected) in [(401, PlaybackFailure.authenticationRequired), (403, .httpForbidden)] {
                let client = fixture.client(overrides: [fixture.detail: Reply("", status: status)])
                await assertFailure(expected, context: "\(fixture.id), HTTP \(status)") {
                    _ = try await client.catalog(fixture.work())
                }
            }
        }
    }

    func testEverySourceRejectsForeignCatalogAndEpisodeIdentities() async throws {
        for fixture in Self.fixtures {
            let client = fixture.client()
            let catalog = try await client.catalog(fixture.work())
            let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
            let foreignID = fixture.id == "girigiri" ? "jibi" : "girigiri"
            let foreignWork = RuntimeWork(item: SourceItemRef(sourceID: foreignID,
                pageURL: fixture.detail, kind: .work), title: fixture.title)
            await assertFailure(.missingEpisode, context: fixture.id) {
                _ = try await client.catalog(foreignWork)
            }
            let foreignEpisode = RuntimeEpisode(item: SourceItemRef(sourceID: foreignID,
                pageURL: selected.item.pageURL, kind: .episode), title: selected.title,
                line: selected.line, number: selected.number)
            await assertFailure(.missingEpisode, context: fixture.id) {
                _ = try await client.resolve(foreignEpisode, in: catalog)
            }
            let foreignCatalog = RuntimeCatalog(work: foreignWork, lines: catalog.lines)
            await assertFailure(.missingEpisode, context: fixture.id) {
                _ = try await client.resolve(selected, in: foreignCatalog)
            }
        }
    }

    func testMacPlayersRejectPaidPreviewAndUnsupportedEncryption() async throws {
        for fixture in [Self.girigiri, Self.jibi, Self.yinghua, Self.youknow] {
            let leaf = fixture.lines[0].leaves[0]
            for (points, preview, encoding) in [(1, 0, 0), (0, 1, 0), (0, 0, 3)] {
                let html = Self.player(leaf, points: points, preview: preview, encoding: encoding)
                let client = fixture.client(overrides: [leaf.page: Reply(html)])
                let catalog = try await client.catalog(fixture.work())
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                await assertFailure(.mediaNotFound, context: "\(fixture.id): paid/preview/encoding") {
                    _ = try await client.resolve(selected, in: catalog)
                }
            }
        }
    }

    func testJibiAndYinghuaDoNotAcceptEncodedPlayerURLs() async throws {
        // Unlike Girigiri and Youknow, these decoders deliberately permit encrypt == 0 only.
        for fixture in [Self.jibi, Self.yinghua] {
            let leaf = fixture.lines[0].leaves[0]
            for encoding in [1, 2] {
                let client = fixture.client(overrides: [leaf.page: Reply(Self.player(leaf, encoding: encoding))])
                let catalog = try await client.catalog(fixture.work())
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                await assertFailure(.mediaNotFound, context: "\(fixture.id): encrypt=\(encoding)") {
                    _ = try await client.resolve(selected, in: catalog)
                }
            }
        }
    }

    func testGirigiriAndYouknowDecodePercentAndBase64PlayerURLs() async throws {
        for fixture in [Self.girigiri, Self.youknow] {
            let leaf = fixture.lines[0].leaves[0]
            for encoding in [1, 2] {
                let client = fixture.client(overrides: [leaf.page: Reply(Self.player(leaf, encoding: encoding))])
                let catalog = try await client.catalog(fixture.work())
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                let resolved = try await client.resolve(selected, in: catalog)
                XCTAssertEqual(resolved.absoluteString, leaf.media, "\(fixture.id): encrypt=\(encoding)")
            }
        }
    }

    func testMacPlayersRejectWrongEpisodeAndIndirectMedia() async throws {
        for fixture in [Self.girigiri, Self.jibi, Self.yinghua, Self.youknow] {
            let leaf = fixture.lines[0].leaves[0]
            let wrongEpisode = Leaf(title: leaf.title, page: leaf.page, sid: leaf.sid,
                number: leaf.number + 20, media: leaf.media)
            let indirect = Leaf(title: leaf.title, page: leaf.page, sid: leaf.sid,
                number: leaf.number, media: "https://media.example/player.html")
            for invalid in [wrongEpisode, indirect] {
                let client = fixture.client(overrides: [leaf.page: Reply(Self.player(invalid))])
                let catalog = try await client.catalog(fixture.work())
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                await assertFailure(.mediaNotFound, context: fixture.id) {
                    _ = try await client.resolve(selected, in: catalog)
                }
            }
        }
    }

    func testEACGAndKanbaRejectLockedPasswordPreviewAndUnsupportedCode() async throws {
        for fixture in [Self.eacg, Self.kanba] {
            let leaf = fixture.lines[0].leaves[0]
            for (lock, pass, preview, code) in [(1, 1, 0, 1), (0, 0, 0, 1), (0, 1, 1, 1), (0, 1, 0, 2)] {
                let html = Self.frame(leaf.media, kanba: fixture.id == "kanba",
                    lock: lock, pass: pass, preview: preview, code: code)
                let client = fixture.client(overrides: [leaf.page: Reply(html)])
                let catalog = try await client.catalog(fixture.work())
                let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
                await assertFailure(.mediaNotFound, context: fixture.id) {
                    _ = try await client.resolve(selected, in: catalog)
                }
            }
        }
    }

    func testSenfunRejectsAPIWithNoDirectUnrestrictedMedia() async throws {
        let fixture = Self.senfun
        let endpoint = "https://senfun.in/_senfun_plays/42/ep_A"
        let client = fixture.client(overrides: [endpoint: Reply("""
            {"video_plays":[{"src_site":"parser","play_data":"https://media.example/player.html"},
            {"src_site":"insecure","play_data":"http://media.example/paid.m3u8"},
            {"src_site":"credentials","play_data":"https://user:secret@media.example/a.mp4"}]}
            """)])
        let catalog = try await fixture.client().catalog(fixture.work())
        let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
        await assertFailure(.mediaNotFound) {
            _ = try await client.playbackOptions(selected, in: catalog)
        }
    }

    func testDilidiliRejectsMismatchedAPIIdentityAndFormat() async throws {
        let fixture = Self.dilidili
        for body in [
            "{\"id\":\"_get_play_9999\",\"result\":{\"play_cfg\":\"m3u8\",\"play_data\":\"https://media.example/a.m3u8\"}}",
            "{\"id\":\"_get_play_7101\",\"result\":{\"play_cfg\":\"mp4\",\"play_data\":\"https://media.example/a.m3u8\"}}"
        ] {
            let client = fixture.client(overrides: [
                "https://dilidili.io/_get_play?id=7101": Reply(body),
                "https://dilidili.io/_get_play?id=7102": Reply(body)
            ])
            let catalog = try await fixture.client().catalog(fixture.work())
            let selected = try XCTUnwrap(catalog.lines.first?.episodes.first)
            await assertFailure(.mediaNotFound) {
                _ = try await client.playbackOptions(selected, in: catalog)
            }
        }
    }

    private func assertFixture(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) async throws {
        let client = fixture.client()
        // Dynamic sources must load only the detail document until an episode is selected.
        // The metadata-only transport deliberately has no watch-page or API fixtures.
        let catalog = try await fixture.client(metadataOnly: fixture.hasDynamicOptions).catalog(fixture.work())
        XCTAssertEqual(catalog.work.item, try fixture.work().item, file: file, line: line)
        XCTAssertEqual(catalog.work.title, fixture.title, file: file, line: line)
        XCTAssertEqual(catalog.lines.map(\.title), fixture.catalogLines.map(\.title), fixture.id, file: file, line: line)
        XCTAssertEqual(catalog.lines.count, fixture.catalogLines.count, file: file, line: line)
        XCTAssertEqual(catalog.lines.map(\.id), fixture.catalogLines.map(\.id), fixture.id, file: file, line: line)
        for (actual, expected) in zip(catalog.lines, fixture.catalogLines) {
            XCTAssertEqual(actual.episodes.map(\.title), expected.leaves.map(\.title), fixture.id, file: file, line: line)
            XCTAssertEqual(actual.episodes.map(\.item.pageURL), expected.leaves.map(\.page), fixture.id, file: file, line: line)
            XCTAssertEqual(actual.episodes.map(\.number), expected.leaves.map(\.number), fixture.id, file: file, line: line)
            XCTAssertEqual(actual.episodes.map(\.item.sourceID), Array(repeating: fixture.id, count: expected.leaves.count), file: file, line: line)
            XCTAssertTrue(actual.episodes.allSatisfy { $0.item.kind == .episode && $0.line == actual.id }, file: file, line: line)
            let quality: String? = fixture.hasDynamicOptions ? nil : "\(expected.title) (\(expected.id))"
            XCTAssertEqual(actual.episodes.map(\.qualityID), Array(repeating: quality, count: expected.leaves.count), file: file, line: line)
            let identities = expected.leaves.map { leaf in
                Optional(fixture.id == "dilidili" ? "dilidili:episode:\(leaf.page)" : "\(fixture.id):42:\(leaf.number)")
            }
            XCTAssertEqual(actual.episodes.map(\.identity), identities, fixture.id, file: file, line: line)
            for (episode, leaf) in zip(actual.episodes, expected.leaves) {
                if fixture.hasDynamicOptions {
                    await assertFailure(.missingMediaQuality, context: fixture.id, file: file, line: line) {
                        _ = try await client.resolve(episode, in: catalog)
                    }
                    let options = try await client.playbackOptions(episode, in: catalog)
                    XCTAssertEqual(options.map(\.title), fixture.lines.map(\.title), file: file, line: line)
                    XCTAssertEqual(options.map(\.qualityID), fixture.lines.map { Optional($0.title) }, file: file, line: line)
                    XCTAssertTrue(options.allSatisfy {
                        $0.item == episode.item && $0.line == episode.line && $0.number == episode.number &&
                        $0.identity == episode.identity && $0.mediaPath == episode.mediaPath
                    }, file: file, line: line)
                    for (option, expectedOption) in zip(options, fixture.lines) {
                        let expectedMedia = try XCTUnwrap(expectedOption.leaves.first { $0.page == leaf.page }, file: file, line: line)
                        let resolved = try await client.resolve(option, in: catalog)
                        XCTAssertEqual(resolved.absoluteString, expectedMedia.media, file: file, line: line)
                    }
                } else {
                    let options = try await client.playbackOptions(episode, in: catalog)
                    XCTAssertEqual(options, [episode], file: file, line: line)
                    let resolved = try await client.resolve(episode, in: catalog)
                    XCTAssertEqual(resolved.absoluteString, leaf.media, "\(fixture.id): \(leaf.page)", file: file, line: line)
                }
            }
        }
    }

    private func assertFailure(_ expected: PlaybackFailure, context: String = "",
        file: StaticString = #filePath, line: UInt = #line, operation: () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected \(expected): \(context)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? PlaybackFailure, expected, "\(context): \(error)", file: file, line: line)
        }
    }

    private struct Leaf: Sendable {
        let title: String
        let page: String
        let sid: Int
        let number: Int
        let media: String
        init(_ title: String, _ page: String, sid: Int, number: Int, source: String) {
            self.init(title: title, page: page, sid: sid, number: number,
                media: "https://media.example/\(source)/\(sid)/\(number).m3u8")
        }
        init(title: String, page: String, sid: Int, number: Int, media: String) {
            self.title = title; self.page = page; self.sid = sid; self.number = number; self.media = media
        }
    }
    private struct Line: Sendable {
        let title: String
        let leaves: [Leaf]
        let id: Int
        init(_ title: String, _ leaves: [Leaf], id: Int? = nil) {
            self.title = title; self.leaves = leaves; self.id = id ?? leaves[0].sid
        }
    }
    private struct Reply: Sendable {
        let body: String
        let status: Int
        init(_ body: String, status: Int = 200) { self.body = body; self.status = status }
    }
    private enum FixtureError: Error { case unexpectedRequest(String) }
    private struct Fixture: Sendable {
        let id: String
        let title: String
        let detail: String
        let html: String
        let lines: [Line]
        var hasDynamicOptions: Bool { id == "senfun" || id == "dilidili" }
        var catalogLines: [Line] { hasDynamicOptions ? [Line(title, lines[0].leaves, id: 1)] : lines }
        func work() throws -> RuntimeWork {
            RuntimeWork(item: try RuntimeSource.native(id).item(detail), title: title)
        }
        func client(overrides: [String: Reply] = [:], metadataOnly: Bool = false) -> NativeSourceClient {
            var routes = [detail: Reply(html)]
            for leaf in (metadataOnly ? [] : lines.flatMap(\.leaves)) {
                switch id {
                case "girigiri", "jibi", "yinghua", "youknow":
                    routes[leaf.page] = Reply(NativeCatalogATests.player(leaf))
                case "eacg", "kanba":
                    routes[leaf.page] = Reply(NativeCatalogATests.frame(leaf.media, kanba: id == "kanba"))
                case "senfun":
                    let slug = URL(string: leaf.page)!.deletingPathExtension().lastPathComponent
                    let options = lines.flatMap(\.leaves).filter { $0.page == leaf.page }
                    let plays = options.enumerated().map { offset, option in
                        "{\"src_site\":\"\(offset == 0 ? "direct" : "backup")\",\"play_data\":\"\(option.media)\"}"
                    }.joined(separator: ",")
                    routes["https://senfun.in/_senfun_plays/42/\(slug)"] = Reply("""
                        {"video_plays":[{"src_site":"invalid","play_data":"http://media.example/rejected.m3u8"},\(plays)]}
                        """)
                case "dilidili":
                    let options = lines.flatMap(\.leaves).filter { $0.page == leaf.page }
                    let buttons = options.enumerated().map { offset, option in
                        let playID = "\(7101 + leaf.number * 10 + offset)"
                        routes["https://dilidili.io/_get_play?id=\(playID)"] = Reply("""
                            {"id":"_get_play_\(playID)","result":{"play_cfg":"m3u8","play_data":"\(option.media)"}}
                            """)
                        return "<button class=\"play-btn\" play_id=\"\(playID)\">\(offset == 0 ? "Direct" : "Backup")</button>"
                    }.joined()
                    routes[leaf.page] = Reply("""
                        <div id="link"><a href="/anime/fixture-show/">Back</a></div>
                        <button class="play-btn" play_id="not-numeric">Ignore</button>\(buttons)
                        """)
                default: break
                }
            }
            routes.merge(overrides, uniquingKeysWith: { _, replacement in replacement })
            let replies = routes
            return NativeSourceClient(sourceID: id, fetch: { request in
                guard let url = request.url, let reply = replies[url.absoluteString] else {
                    throw FixtureError.unexpectedRequest(request.url?.absoluteString ?? "nil")
                }
                return SourceHTTPResponse(data: Data(reply.body.utf8), url: url, statusCode: reply.status)
            })
        }
    }

    private static func player(_ leaf: Leaf, points: Int = 0, preview: Int = 0, encoding: Int = 0) -> String {
        let percent = leaf.media.replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: "/", with: "%2F")
        let encoded = encoding == 2 ? Data(percent.utf8).base64EncodedString() : encoding == 1 ? percent : leaf.media
        return """
            <script>var player_aaaa={"id":"42","sid":\(leaf.sid),"nid":\(leaf.number),"points":\(points),"trysee":\(preview),"encrypt":\(encoding),"url":"\(encoded)"};</script>
            """
    }
    private static func frame(_ media: String, kanba: Bool, lock: Int = 0, pass: Int = 1,
        preview: Int = 0, code: Int = 1) -> String {
        let base64 = Data(media.utf8).base64EncodedString()
        // EACG strips three prefix characters; Kanba restores a missing initial base64 'a'
        // after removing its four-character salt, and restores omitted base64 padding.
        let payload = kanba ? "salt" + base64.dropFirst().replacingOccurrences(of: "=", with: "") : "abc" + base64
        return """
            <iframe id="fed-play-iframe" data-lock="\(lock)" data-pass="\(pass)" data-trys="\(preview)" data-code="\(code)" data-play="\(payload)"></iframe>
            """
    }

    private static let girigiri = Fixture(id: "girigiri", title: "Girigiri Fixture",
        detail: "https://ani.girigirilove.com/GV42/", html: """
        <div class="detail-info"><h1 class="slide-info-title">Girigiri Fixture</h1></div>
        <div class="anthology-tab"><div class="swiper-slide">Primary<span>2</span></div><div class="swiper-slide">Backup</div></div>
        <div class="anthology-list-box">
          <a href="/playGV42-1-2/">Episode Two</a><a href="/playGV42-1-5/">Episode Five</a>
          <a href="/playGV99-1-1/">Wrong Work</a><a href="/playGV42-2-8/">Wrong Line</a>
          <a href="https://unrelated.example/playGV42-1-3/">Foreign</a>
        </div><div class="anthology-list-box"><a href="/playGV42-2-9/">Episode Nine</a></div>
        """, lines: [Line("Primary", [
            Leaf("Episode Two", "https://ani.girigirilove.com/playGV42-1-2/", sid: 1, number: 2, source: "girigiri"),
            Leaf("Episode Five", "https://ani.girigirilove.com/playGV42-1-5/", sid: 1, number: 5, source: "girigiri")]),
            Line("Backup", [Leaf("Episode Nine", "https://ani.girigirilove.com/playGV42-2-9/", sid: 2, number: 9, source: "girigiri")])])

    private static let jibi = Fixture(id: "jibi", title: "Jibi Fixture",
        detail: "https://www.jibi.cc/index.php/vod/detail/id/42.html", html: """
        <div class="module-info-heading"><h1>Jibi Fixture</h1></div>
        <div class="module-tab-item" data-dropdown-value="叽哔2线"></div><div class="module-tab-item" data-dropdown-value="叽哔7线"></div>
        <div class="module-play-list">
          <a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/7/nid/2.html">Episode Two</a>
          <a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/7/nid/5.html">Episode Five</a>
          <a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/2/nid/8.html">Mixed Line</a>
          <a class="module-play-list-link" href="/index.php/vod/play/id/99/sid/7/nid/1.html">Wrong Work</a>
        </div><div class="module-play-list"><a class="module-play-list-link" href="/index.php/vod/play/id/42/sid/2/nid/9.html">Episode Nine</a></div>
        """, lines: [Line("叽哔7线", [
            Leaf("Episode Two", "https://www.jibi.cc/index.php/vod/play/id/42/sid/7/nid/2.html", sid: 7, number: 2, source: "jibi"),
            Leaf("Episode Five", "https://www.jibi.cc/index.php/vod/play/id/42/sid/7/nid/5.html", sid: 7, number: 5, source: "jibi")]),
            Line("叽哔2线", [Leaf("Episode Nine", "https://www.jibi.cc/index.php/vod/play/id/42/sid/2/nid/9.html", sid: 2, number: 9, source: "jibi")])])

    private static let eacg = Fixture(id: "eacg", title: "EACG Fixture",
        detail: "https://www.eacg1.com/voddetails-42.html", html: """
        <div class="fed-deta-info"><h1>EACG Fixture</h1></div><div class="fed-tabs-boxs">
        <div class="fed-play-btns"><a>Direct Seven</a><a>Backup Two</a></div>
        <div class="fed-play-item"><a href="/Comicplay/42-7-2.html">Episode Two</a><a href="/vodplay/42-7-5.html">Episode Five</a>
        <a href="/Comicplay/99-7-1.html">Wrong Work</a><a href="/Comicplay/42-2-8.html">Mixed Line</a></div>
        <div class="fed-play-item"><a href="/Comicplay/42-2-9.html">Episode Nine</a></div></div>
        """, lines: [Line("Direct Seven", [
            Leaf("Episode Two", "https://www.eacg1.com/Comicplay/42-7-2.html", sid: 7, number: 2, source: "eacg"),
            Leaf("Episode Five", "https://www.eacg1.com/vodplay/42-7-5.html", sid: 7, number: 5, source: "eacg")]),
            Line("Backup Two", [Leaf("Episode Nine", "https://www.eacg1.com/Comicplay/42-2-9.html", sid: 2, number: 9, source: "eacg")])])

    private static let kanba = Fixture(id: "kanba", title: "Kanba Fixture",
        detail: "https://11kt.net/index.php/vod/detail/id/42.html", html: """
        <div class="fed-deta-info"><h1>Kanba Fixture</h1></div><div class="fed-tabs-boxs">
        <div class="fed-play-btns"><a>Direct Seven</a><a>Backup Two</a></div>
        <div class="fed-play-item">
        <a href="/index.php/vod/play/id/42/sid/7/nid/2.html">Episode Two</a>
        <a href="/index.php/vod/play/id/42/sid/7/nid/2.html">Duplicate</a>
        <a href="/index.php/vod/play/id/42/sid/7/nid/5.html">Episode Five</a>
        <a href="/index.php/vod/play/id/42/sid/2/nid/8.html">Mixed Line</a></div>
        <div class="fed-play-item"><a href="/index.php/vod/play/id/42/sid/2/nid/9.html">Episode Nine</a></div></div>
        """, lines: [Line("Direct Seven", [
            Leaf("Episode Two", "https://11kt.net/index.php/vod/play/id/42/sid/7/nid/2.html", sid: 7, number: 2, source: "kanba"),
            Leaf("Episode Five", "https://11kt.net/index.php/vod/play/id/42/sid/7/nid/5.html", sid: 7, number: 5, source: "kanba")]),
            Line("Backup Two", [Leaf("Episode Nine", "https://11kt.net/index.php/vod/play/id/42/sid/2/nid/9.html", sid: 2, number: 9, source: "kanba")])])

    private static let senfun = Fixture(id: "senfun", title: "Senfun Fixture",
        detail: "https://senfun.in/voddetail/42.html", html: """
        <div class="module-info-heading"><h1>Senfun Fixture</h1></div>
        <div class="module-play-list-content"><a href="/vodwatch/42/ep_A.html">Episode A</a>
        <a href="/vodwatch/99/foreign.html">Wrong Work</a><a href="https://unrelated.example/vodwatch/42/foreign.html">Foreign</a></div>
        <div class="module-play-list-content"><a href="/vodwatch/42/ep_B2.html">Episode B</a></div>
        """, lines: [Line("DIRECT (1)", [
            Leaf("Episode A", "https://senfun.in/vodwatch/42/ep_A.html", sid: 1, number: 1, source: "senfun"),
            Leaf("Episode B", "https://senfun.in/vodwatch/42/ep_B2.html", sid: 1, number: 2, source: "senfun")]),
            Line("BACKUP (2)", [
                Leaf("Episode A", "https://senfun.in/vodwatch/42/ep_A.html", sid: 2, number: 1, source: "senfun"),
                Leaf("Episode B", "https://senfun.in/vodwatch/42/ep_B2.html", sid: 2, number: 2, source: "senfun")])])

    private static let yinghua = Fixture(id: "yinghua", title: "Yinghua Fixture",
        detail: "https://www.yinghuabb.com/index.php/vod/detail/id/42.html", html: """
        <div class="stui-content__detail"><h1>Yinghua Fixture<span>Ignore subtitle</span></h1></div>
        <div class="stui-pannel-box playlist"><h3 class="title">Displayed Line One</h3><div class="stui-content__playlist">
        <a href="/index.php/vod/play/id/42/sid/7/nid/2.html">第02集</a>
        <a href="/index.php/vod/play/id/42/sid/7/nid/2.html">Duplicate</a>
        <a href="/index.php/vod/play/id/42/sid/7/nid/5.html">第05集</a>
        <a href="/index.php/vod/play/id/42/sid/2/nid/8.html">Mixed Line</a></div></div>
        <div class="stui-pannel-box playlist"><h3 class="title">Displayed Line Two</h3><div class="stui-content__playlist">
        <a href="/index.php/vod/play/id/42/sid/2/nid/9.html">第09集</a></div></div>
        """, lines: [Line("Displayed Line One", [
            Leaf("第02集", "https://www.yinghuabb.com/index.php/vod/play/id/42/sid/7/nid/2.html", sid: 7, number: 2, source: "yinghua"),
            Leaf("第05集", "https://www.yinghuabb.com/index.php/vod/play/id/42/sid/7/nid/5.html", sid: 7, number: 5, source: "yinghua")]),
            Line("Displayed Line Two", [Leaf("第09集", "https://www.yinghuabb.com/index.php/vod/play/id/42/sid/2/nid/9.html", sid: 2, number: 9, source: "yinghua")])])

    private static let dilidili = Fixture(id: "dilidili", title: "Dilidili Fixture",
        detail: "https://dilidili.io/anime/fixture-show/", html: """
        <h1>Dilidili Fixture</h1><div class="swiper-slide">
        <a href="/watch/fixture-a/"><img src="a.jpg"><span>Episode A</span>Ignored extra</a>
        <a href="/watch/fixture-a/"><span>Duplicate</span></a>
        <a href="https://unrelated.example/watch/foreign/">Foreign</a>
        <a href="/anime/another-show/">Not an episode</a>
        <a href="/watch/fixture-b/">Episode B</a></div>
        """, lines: [Line("Direct (1)", [
            Leaf("Episode A", "https://dilidili.io/watch/fixture-a/", sid: 1, number: 0, source: "dilidili"),
            Leaf("Episode B", "https://dilidili.io/watch/fixture-b/", sid: 1, number: 1, source: "dilidili")], id: 0),
            Line("Backup (2)", [
                Leaf("Episode A", "https://dilidili.io/watch/fixture-a/", sid: 2, number: 0, source: "dilidili"),
                Leaf("Episode B", "https://dilidili.io/watch/fixture-b/", sid: 2, number: 1, source: "dilidili")], id: 1)])

    private static let youknow = Fixture(id: "youknow", title: "Youknow Fixture",
        detail: "https://www.youknow.tv/d/42/", html: """
        <div class="module-info-heading"><h1>Youknow Fixture</h1></div>
        <div class="module-tab-item" data-source-sid="2"><span>Backup Two</span></div>
        <div class="module-tab-item" data-source-sid="7"><span>Direct Seven</span></div>
        <div class="y-source-panel" data-source-sid="7">
        <a class="module-play-list-link" href="/p/42-7-2/">Episode Two</a>
        <a class="module-play-list-link" href="/p/42-7-2/">Duplicate</a>
        <a class="module-play-list-link" href="/p/42-7-5/">Episode Five</a>
        <a class="module-play-list-link" href="/p/42-2-8/">Wrong Line</a>
        <a class="module-play-list-link" href="/p/99-7-1/">Wrong Work</a></div>
        <div class="y-source-panel" data-source-sid="2"><a class="module-play-list-link" href="/p/42-2-9/">Episode Nine</a></div>
        """, lines: [Line("Direct Seven", [
            Leaf("Episode Two", "https://www.youknow.tv/p/42-7-2/", sid: 7, number: 2, source: "youknow"),
            Leaf("Episode Five", "https://www.youknow.tv/p/42-7-5/", sid: 7, number: 5, source: "youknow")]),
            Line("Backup Two", [Leaf("Episode Nine", "https://www.youknow.tv/p/42-2-9/", sid: 2, number: 9, source: "youknow")])])

    private static var fixtures: [Fixture] { [girigiri, jibi, eacg, kanba, senfun, yinghua, dilidili, youknow] }
}
