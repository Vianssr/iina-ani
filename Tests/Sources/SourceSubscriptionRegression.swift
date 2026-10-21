import Foundation
@testable import IINA_ANI

@main enum SourceSubscriptionRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure.assertion(message) }
    }
    static func source(_ name: String, _ url: String, selector: String = ".results h4 > a", format: String = "a",
                       names: String? = nil, links: String? = nil, version: Int = 2, factory: String = "web-selector") -> [String: Any] {
        var config: [String: Any] = ["searchUrl": url, "subjectFormatId": format,
                                    "selectorSubjectFormatA": ["selectLists": selector]]
        if let names, let links { config["selectorSubjectFormatIndexed"] = ["selectNames": names, "selectLinks": links] }
        // These must never become part of a persisted search override.
        config["matchVideo"] = ["cookies": "private-cookie", "addHeadersToVideo": ["Authorization": "private-token"],
                                "matchVideoUrl": "private-regex", "scanInlineScriptUrls": true]
        config["script"] = "private-script"
        return ["factoryId": factory, "version": version, "arguments": ["name": name, "searchConfig": config,
                 "headers": ["Cookie": "private-cookie"], "token": "private-token"]]
    }
    static func feed(_ items: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": items]], options: [.sortedKeys])
    }
    static func decoded(_ plan: SourceSubscriptionPlan, _ id: String) throws -> NativeSearchSource {
        guard let data = plan.overrides[id] else { throw Failure.assertion("missing override: \(id)") }
        return try JSONDecoder().decode(NativeSearchSource.self, from: data)
    }
    static func expectFailure(_ data: Data, registry: SourceRegistry, _ expected: SourceSubscriptionError) throws {
        do {
            _ = try SourceSubscriptionConverter.convert(data: data, registry: registry)
            throw Failure.assertion("invalid subscription accepted")
        } catch let error as SourceSubscriptionError {
            try require(error == expected, "wrong feed error category")
        }
    }

    @MainActor static func main() async throws {
        let root = CommandLine.arguments.count > 1 ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) :
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let builtin = root.appendingPathComponent("IINA-ANI/Sources", isDirectory: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("iina-subscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let registry = SourceRegistry(builtinDirectory: builtin, userDirectory: temporary)
        try require(registry.loadError == nil, "isolated baseline failed to load")

        // These indexed selectors are the actual css1 v2 shapes, not a universal indexed-list parser.
        let xifan = source("稀饭动漫", "https://dm1.xfdm.pro/search.html?wd={keyword}", format: "indexed",
                           names: "body > .box-width .search-box .thumb-content > .thumb-txt",
                           links: "body > .box-width .search-box .thumb-menu > a")
        let girigiri = source("girigiri愛動漫", "https://ani.girigirilove.com/search/-------------/?wd={keyword}", format: "indexed",
                              names: "body > .box-width .vod-detail .detail-info .slide-info-title",
                              links: "body > .box-width .vod-detail .detail-info > a")
        let hanime = source("hanime1_1080p", "https://hanime1.me/search?query={keyword}", format: "indexed",
                            names: "#home-rows-wrapper > div.content-padding-new > div > div > div > div > a > div.title",
                            links: "#home-rows-wrapper > div.content-padding-new > div > div > div> div > a")
        var hanime720 = hanime
        var hanimeArguments = hanime720["arguments"] as! [String: Any]
        hanimeArguments["name"] = "hanime1_720p"
        hanime720["arguments"] = hanimeArguments
        let fengche = source("风车影视", "https://www.dongmandaquan.vip/vodsearch/-------------.html?wd={keyword}",
                             selector: ".post-list .block-info .entry-title>a")
        let haixing = source("海星动漫", "https://www.haixingdmx.com/s_all?ex=1&kw={keyword}", selector: "div ul li h2 > a")
        let yinghua = source("樱花动漫", "https://www.yinghua2.com/index.php/vod/search.html?wd={keyword}", selector: ".title > a")
        let rebo = source("热播之家", "https://www.rebozj.pro/search/-------------.html?wd={keyword}&submit=", selector: ".stui-vodlist__box h4 > a")
        let fqdm = source("番茄动漫", "https://www.fqdm.cc/index.php/vod/search.html?wd={keyword}",
                          selector: "div.module-card-item-info > div.module-card-item-title > a")
        let changed = source("叽哔动漫", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", selector: ".new-results > a")
        let plan = try SourceSubscriptionConverter.convert(data: feed([xifan, girigiri, hanime, hanime720, fengche, haixing, yinghua, rebo, fqdm, changed]), registry: registry)
        try require(plan.overrides.count == 9 && plan.overrides["forest"] == nil, "Hanime variants must consolidate without extra playback identities")
        try require(plan.entries.filter { $0.sourceID != nil && plan.overrides[$0.sourceID!] != nil }.allSatisfy { $0.status == "待啟用" },
                    "initial subscription preview must require explicit activation, including unchanged baselines")
        let jibi = try decoded(plan, "jibi")
        try require(jibi.search.resultsSelector == ".new-results > a" && jibi.search.titleSelector == "self" &&
                    jibi.search.linkSelector == nil && jibi.search.hrefAttribute == "href", "a selector must map to row/self/link identity")
        try require(jibi.search.url.contains("{query}") && !jibi.search.url.contains("{keyword}"), "query placeholder was not transformed")
        for (id, host) in [("yinghua", "www.yinghua2.com"), ("rebo", "www.rebozj.pro")] {
            let converted = try decoded(plan, id)
            let request = try SourceSearchExecutor.requestURL(converted.search, query: "海贼王 & /", page: 2, allowedHosts: Set(converted.hosts))
            let address = URLComponents(url: request, resolvingAgainstBaseURL: false)!
            try require(address.host == host, "source matching must request the subscribed host instead of a pinned replacement: \(id)")
            try require(address.queryItems?.first(where: { $0.name == "wd" })?.value == "海贼王 & /" &&
                        address.queryItems?.first(where: { $0.name == converted.search.pageParameter })?.value == "2",
                        "subscribed links must preserve escaped work names and requested page")
        }
        for encoded in plan.overrides.values {
            let text = String(decoding: encoded, as: UTF8.self)
            try require(!text.contains("private-") && !text.contains("cookies") && !text.contains("headers") && !text.contains("script"), "credentials or remote playback instructions escaped whitelist")
            let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            try require(Set(object.keys).isSubset(of: ["hosts", "search", "resultURLTemplate"]), "override has non-search fields")
        }
        let repeatPlan = try SourceSubscriptionConverter.convert(data: feed([xifan, girigiri, hanime, hanime720, fengche, haixing, yinghua, rebo, fqdm, changed]), registry: registry)
        try require(plan.fingerprint == repeatPlan.fingerprint && plan.overrides == repeatPlan.overrides, "same feed conversion must be deterministic apart from check time")

        let duplicate = source("duplicate", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", selector: ".other > a")
        let conflictingOrders: [[Any]] = [[changed, duplicate, fqdm], [duplicate, changed, fqdm]]
        for items in conflictingOrders {
            let conflicts = try SourceSubscriptionConverter.convert(data: feed(items), registry: registry)
            try require(conflicts.overrides["jibi"] == nil && conflicts.overrides["fqdm"] != nil, "conflict must reject only that source independent of order")
        }
        let same = try SourceSubscriptionConverter.convert(data: feed([changed, changed]), registry: registry)
        try require(same.overrides.count == 1, "identical duplicates should consolidate")
        let invalidDuplicate = source("new parser", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", format: "jsonpath-indexed")
        let rejectedDuplicate = try SourceSubscriptionConverter.convert(data: feed([changed, invalidDuplicate]), registry: registry)
        try require(rejectedDuplicate.overrides["jibi"] == nil, "unsupported duplicate must not let first valid entry win")

        let unsupported: [Any] = [
            source("叽哔动漫", "https://jibi.cc.attacker.invalid/index.php/vod/search.html?wd={keyword}"),
            source("影视森林", "http://www.hc34567.com/hcvodsearch/{keyword}----------1---.html"),
            source("HTTP", "http://www.jibi.cc/index.php/vod/search.html?wd={keyword}"),
            source("user info", "https://user:secret@www.jibi.cc/index.php/vod/search.html?wd={keyword}"),
            source("query token", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}&token=secret"),
            source("auth path", "https://www.jibi.cc/login?wd={keyword}"),
            source("version", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", version: 3),
            source("factory", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", factory: "remote-script"),
            source("indexed unknown shape", "https://dm1.xfdm.pro/search.html?wd={keyword}", format: "indexed", names: ".new-name", links: ".new-link"),
            source("long selector", "https://www.fqdm.cc/index.php/vod/search.html?wd={keyword}", selector: String(repeating: "a", count: 1025))
        ]
        let unsupportedPlan = try SourceSubscriptionConverter.convert(data: feed(unsupported), registry: registry)
        try require(unsupportedPlan.overrides.isEmpty, "unknown/excluded/unsafe entries gained fake playback")
        let remaining: [Any] = [
            source("嘀嗒影视", "https://www.didahd.pro/search/-------------.html?wd={keyword}&submit=", selector: ".myui-vodlist__media h4 > a"),
            source("E-ACG", "https://www.eacg1.com/vodsearch/-------------.html?wd={keyword}", selector: "body > div.fed-main-info.fed-min-width > div > div > dl > dd.fed-deta-content > h1 a"),
            source("森之屋动漫", "https://senfun.in/search.html?wd={keyword}", selector: "div.module-card-item-title > a"),
            source("去看吧", "https://11kt.net/index.php/vod/search.html?wd={keyword}", selector: ".fed-part-eone.fed-font-xvi a"),
            source("嘀哩嘀哩", "https://dilidili.io/search?q={keyword}", selector: "dl h3 a[href^='/anime/']"),
            source("新优酷", "https://www.youknow.tv/search/-------------/?wd={keyword}", selector: ".module-card-item-title > a"),
            source("wedm", "https://www.vdm5.com/search_-------------.html?wd={keyword}", selector: "div.detail > h3 > a")
        ]
        let transformedFixtures: [Any] = [xifan, girigiri, hanime, hanime720, fengche, haixing, yinghua, rebo, fqdm, changed]
        let completeFeed = try feed(transformedFixtures + remaining)
        let complete = try SourceSubscriptionConverter.convert(data: completeFeed, registry: registry)
        try require(Set(complete.overrides.keys) == SourceSubscriptionConverter.managedSourceIDs, "one of the 16 supported search identities was lost")
        let malformedSelector = source("invalid CSS", "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}", selector: "a[")
        let partial = try SourceSubscriptionConverter.convert(data: feed([malformedSelector, fqdm, NSNull()]), registry: registry)
        try require(partial.overrides["jibi"] == nil && partial.overrides["fqdm"] != nil, "invalid individual selector must not invalidate unrelated entries")
        let empty = try SourceSubscriptionConverter.convert(data: feed([]), registry: registry)
        try require(empty.overrides.isEmpty, "missing sources must not manufacture overrides")
        try expectFailure(Data("{bad".utf8), registry: registry, .malformed)
        try expectFailure(Data("{}".utf8), registry: registry, .malformed)
        try expectFailure(feed([1, "bad", NSNull()]), registry: registry, .malformed)
        try expectFailure(Data(repeating: 32, count: 2 * 1024 * 1024 + 1), registry: registry, .tooLarge)
        try expectFailure(feed(Array(repeating: fqdm, count: 129)), registry: registry, .tooManyItems)
        print("PASS css1 converter: real selector shapes, local pins, search-only whitelist, identity isolation, duplicate rejection, unsupported/missing preservation and bounded feed errors")
    }
}
