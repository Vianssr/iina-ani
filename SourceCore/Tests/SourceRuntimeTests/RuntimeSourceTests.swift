import XCTest
import SourceCore
@testable import SourceRuntime

final class RuntimeSourceTests: XCTestCase {
    func testAllApprovedIdentitiesHaveRealMetadata() throws {
        let sources = try RuntimeSource.builtins()
        let expected: Set<String> = ["xifan", "girigiri", "didahd", "jibi", "eacg", "senfun", "kanba", "haixing", "yinghua", "dilidili", "youknow", "hanime1", "wedm", "fengche", "rebo", "mutedm", "fqdm"]
        XCTAssertEqual(Set(sources.map(\.id)), expected)
        XCTAssertEqual(sources.count, 17)
        for source in sources {
            XCTAssertFalse(source.hosts.isEmpty)
            XCTAssertEqual(source.configurationRevision.count, 71)
            XCTAssertTrue(source.configurationRevision.hasPrefix("sha256:"))
            XCTAssertEqual(source.configurationRevision, try RuntimeSource.builtins().first(where: { $0.id == source.id })?.configurationRevision)
            if source.id != "fqdm" {
                XCTAssertNil(source.configured)
                XCTAssertNil(source.search, "Packaged native baselines are not active subscription overlays")
            } else { XCTAssertNotNil(source.configured); XCTAssertNotNil(source.search) }
        }
        XCTAssertTrue(RuntimeSource.native("hanime1").effectiveCapabilities(on: .iOS).contains(.quality))
        XCTAssertFalse(RuntimeSource.native("unknown").effectiveCapabilities(on: .iOS).contains(.resolve))
    }

    func testNativeRoutesAndDistinctNextNamespace() throws {
        let cases: [(String, String, SourceItemRef.Kind)] = [
            ("xifan", "https://dm1.xfdm.pro/bangumi/42.html", .work),
            ("xifan", "https://next.xifanacg.com/anime/44/play/501?source=xfxf1", .episode),
            ("girigiri", "https://ani.girigirilove.com/GV42/", .work),
            ("didahd", "https://www.didahd.xyz/detail/42.html", .work),
            ("jibi", "https://www.jibi.cc/index.php/vod/detail/id/42.html", .work),
            ("eacg", "https://www.eacg1.com/voddetails-42.html", .work),
            ("senfun", "https://senfun.in/vodwatch/42/slug.html", .episode),
            ("kanba", "https://11kt.net/index.php/vod/play/id/42/sid/2/nid/7.html", .episode),
            ("haixing", "https://www.haixingdmx.com/play/abc42-0-0.html", .episode),
            ("yinghua", "https://www.yinghuabb.com/index.php/vod/detail/id/42.html", .work),
            ("dilidili", "https://dilidili.io/anime/fixture/", .work),
            ("youknow", "https://www.youknow.tv/d/42/", .work),
            ("hanime1", "https://hanime1.me/watch?v=42", .video),
            ("wedm", "https://www.vdm5.com/vodetail_fixture.html", .work),
            ("fengche", "https://www.dongmandaquan.vip/voddetail/42.html", .work),
            ("rebo", "https://www.rebozj.cc/detail/42.html", .work),
            ("mutedm", "https://www.2kdm.com/vodplay/42-3-7.html", .episode)
        ]
        for (id, page, kind) in cases {
            let item = try RuntimeSource.native(id).item(page)
            XCTAssertEqual(item.sourceID, id); XCTAssertEqual(item.kind, kind); XCTAssertEqual(item.pageURL, page)
        }
        XCTAssertThrowsError(try RuntimeSource.native("xifan").item("https://next.xifanacg.com/bangumi/42.html"))
        XCTAssertThrowsError(try RuntimeSource.native("jibi").item("https://www.jibi.cc.evil.test/index.php/vod/detail/id/42.html"))
        XCTAssertThrowsError(try RuntimeSource.native("mutedm").item("https://user:password@www.mutedm.com/voddetail/42.html"))
        XCTAssertThrowsError(try RuntimeSource.native("didahd").item("https://www.didahd.xyz:8443/detail/42.html"))
    }

    func testMappingPreservesNextSourceAndHanimeQuality() throws {
        let xifan = RuntimeSource.native("xifan")
        let work = try xifan.item("https://next.xifanacg.com/anime/44")
        let episode = try xifan.item("https://next.xifanacg.com/anime/44/play/501?source=xfxf1")
        let choice = PlayableSelection(item: work, episode: episode, lineID: "1", qualityID: "Cloud", accountID: UUID(), classification: xifan.classification)
        let safe = try xifan.mappingSelection(choice)
        XCTAssertEqual(safe.episode, episode); XCTAssertEqual(safe.qualityID, choice.qualityID); XCTAssertNil(safe.accountID)
        let hanime = RuntimeSource.native("hanime1")
        let video = try hanime.item("https://hanime1.me/watch?v=42")
        let quality = PlayableSelection(item: video, episode: video, lineID: "0", qualityID: "720p", classification: .unknown)
        XCTAssertEqual(try hanime.mappingSelection(quality), quality)
    }
}
