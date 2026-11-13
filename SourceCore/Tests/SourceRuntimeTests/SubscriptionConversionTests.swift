import Foundation
import XCTest
import SourceCore
@testable import SourceRuntime

final class SubscriptionConversionTests: XCTestCase {
    private func baseline(hosts: [String] = ["catalog.example"]) throws -> NativeSearchSource {
        let data = Data(#"{"url":"https://catalog.example/old?wd={query}","format":"html","queryParameter":"wd","pageParameter":"p","rowsPerPage":24,"firstPage":0,"resultsSelector":".old","titleSelector":"self","hrefAttribute":"href"}"#.utf8)
        return NativeSearchSource(hosts: hosts, search: try JSONDecoder().decode(SourceConfiguration.Search.self, from: data))
    }
    private static func item(_ raw: String) -> SourceItemRef? {
        guard let url = URL(string: raw), url.scheme == "https", url.host == "catalog.example", url.user == nil else { return nil }
        return SourceItemRef(sourceID: "custom", pageURL: raw, kind: .work)
    }
    private func indexed(_ names: String = ".name", _ links: String = "a.result") -> [String: Any] {
        ["searchUrl": "https://catalog.example/new/{keyword}?kind=anime", "subjectFormatId": "indexed",
         "selectorSubjectFormatIndexed": ["selectNames": names, "selectLinks": links]]
    }
    private func feed(_ configs: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["mediaSources": configs.map {
            ["factoryId": "web-selector", "version": 2, "arguments": ["name": "Untrusted display name", "searchConfig": $0]]
        }])
    }
    private func parse(_ html: String, source: NativeSearchSource) throws -> SourceSearchPage {
        try SourceSearchExecutor.parse(data: Data(html.utf8), spec: source.search, page: 1,
            responseURL: URL(string: "https://catalog.example/search")!, resultURLTemplate: source.resultURLTemplate,
            item: { Self.item($0) })
    }
    private func staticConfig(_ host: String = "catalog.example") -> [String: Any] {
        ["searchUrl": "https://\(host)/search?q={keyword}", "subjectFormatId": "a",
         "selectorSubjectFormatA": ["selectLists": "a.result"], "channelFormatId": "index-grouped",
         "selectorChannelFormatFlattened": ["selectChannelNames": ".line", "selectEpisodeLists": ".episodes", "selectEpisodesFromList": "a"]]
    }

    func testCustomBaselineHostsAndPathTemplatesAreConvertedWithoutNameInference() throws {
        let local = try baseline()
        let plan = try SourceSubscriptionConverter.convert(data: feed([indexed()]), baselines: ["custom": local], installed: [:], names: [:])
        let source = try JSONDecoder().decode(NativeSearchSource.self, from: XCTUnwrap(plan.overrides["custom"]))
        XCTAssertEqual(source.search.indexedNamesSelector, ".name")
        XCTAssertNil(source.search.resultsSelector)
        XCTAssertEqual(source.search.rowsPerPage, 24)
        XCTAssertEqual(source.search.firstPage, 0)
        let request = try SourceSearchExecutor.requestURL(source.search, query: "海贼王 & /", page: 2, allowedHosts: Set(local.hosts))
        XCTAssertEqual(URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "p" }?.value, "1")
        XCTAssertTrue(request.absoluteString.contains("%26%20%2F"))
        XCTAssertFalse(request.absoluteString.contains("{query}"))
        let unknown = try SourceSubscriptionConverter.convert(data: feed([indexed()]), baselines: [:], installed: [:], names: [:])
        XCTAssertTrue(unknown.overrides.isEmpty)
    }

    func testIndexedPairsUseDOMStructureAndNeverBridgeMissingRows() throws {
        let source = try SourceSubscriptionConverter.convertSearch(config: indexed(), baseline: baseline())
        let html = "<div><article><a class=result href='/work/1'></a><span class=name>One</span></article><article><span class=name>Two</span><a class=result href='/work/2'></a></article></div>"
        let result = try parse(html, source: source)
        XCTAssertEqual(result.results.map(\.title), ["One", "Two"])
        XCTAssertEqual(result.results.map(\.item.pageURL), ["https://catalog.example/work/1", "https://catalog.example/work/2"])
        // Equal global lengths still cannot pair a title in one row to a link in another.
        XCTAssertThrowsError(try parse("<div><article><span class=name>One</span></article><article><a class=result href='/wrong'></a></article><article><span class=name>Two</span><a class=result href='/two'></a></article></div>", source: source))
        XCTAssertThrowsError(try parse("<article><span class=name>One</span><span class=name>Two</span><a class=result href='/one'></a></article>", source: source))
    }

    func testNestedNamesPairWithTheirOwnAnchorAndInvalidLinksDoNotShiftTitles() throws {
        let source = try SourceSubscriptionConverter.convertSearch(config: indexed(), baseline: baseline())
        let html = "<article><a class=result href='https://external.example/wrong'><span class=name>Rejected</span></a></article><article><a class=result href='/right'><span class=name>Right</span></a></article>"
        let result = try parse(html, source: source)
        XCTAssertEqual(result.results.map(\.title), ["Right"])
        XCTAssertEqual(result.results.first?.item.pageURL, "https://catalog.example/right")
    }

    func testVerificationPagesAreRejectedInsteadOfReturningEmptySearchResults() throws {
        let source = try SourceSubscriptionConverter.convertSearch(config: indexed(), baseline: baseline())
        for html in ["<title>系统安全验证</title><form action='/index.php/ajax/verify_check'></form>",
                     "<form action='/ajax/verify_check?type=search'></form>", "<div id='cf-error-details'></div>"] {
            XCTAssertThrowsError(try parse(html, source: source)) { error in
                guard case SourceSearchError.malformedResponse = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
        XCTAssertTrue(try parse("<html><body>No results</body></html>", source: source).results.isEmpty)
    }

    func testIdenticalIndexedSelectorsConvertToAnchorRowsIncludingJibi() throws {
        let baselines = try SourceSubscriptionBaselines.load()
        var config = indexed(".module-card-item-title > a", ".module-card-item-title > a")
        config["searchUrl"] = "https://www.jibi.cc/index.php/vod/search.html?wd={keyword}"
        let plan = try SourceSubscriptionConverter.convert(data: feed([config]), baselines: baselines, installed: [:], names: [:])
        let source = try JSONDecoder().decode(NativeSearchSource.self, from: XCTUnwrap(plan.overrides["jibi"]))
        XCTAssertEqual(source.search.resultsSelector, ".module-card-item-title > a")
        XCTAssertNil(source.search.indexedNamesSelector)
    }

    func testJSONPathProjectsFieldsFromSameRowWithFallbackKeysAndRelativeBase() throws {
        let config: [String: Any] = ["searchUrl": "https://catalog.example/api?q={keyword}", "rawBaseUrl": "https://catalog.example/video/",
            "subjectFormatId": "json-path-indexed", "selectorSubjectFormatJsonPathIndexed": [
                "selectNames": "$.data.videos[*]['title', 'name']", "selectLinks": "$.data.videos[*]['url', 'slug']"]]
        let source = try SourceSubscriptionConverter.convertSearch(config: config, baseline: baseline())
        let result = try parse(#"{"data":{"videos":[{"title":"Ignored"},{"name":"Two","slug":"second"},{"title":"Three","url":"/third"}]}}"#, source: source)
        XCTAssertEqual(result.results.map(\.title), ["Two", "Three"])
        XCTAssertEqual(result.results.map(\.item.pageURL), ["https://catalog.example/video/second", "https://catalog.example/third"])
        XCTAssertEqual(source.search.jsonResultsPath, "data.videos")
    }

    func testJSONRootArrayAndExplicitURLTemplateDoNotReuseLocalDetailTemplate() throws {
        let config: [String: Any] = ["searchUrl": "https://catalog.example/api?q={query}", "subjectFormatId": "json-path-indexed",
            "selectorSubjectFormatJsonPathIndexed": ["selectNames": "$[*].title", "selectLinks": "$[*].id", "linkTemplate": "/detail/{value}.html"]]
        let local = try baseline()
        let source = try SourceSubscriptionConverter.convertSearch(config: config,
            baseline: NativeSearchSource(hosts: local.hosts, search: local.search, resultURLTemplate: "https://catalog.example/old/{id}"))
        let result = try parse(#"[{"title":"One","id":7},{"title":"Boolean invalid","id":true}]"#, source: source)
        XCTAssertEqual(result.results.map(\.item.pageURL), ["https://catalog.example/detail/7.html"])
        XCTAssertNil(source.resultURLTemplate)
    }

    func testUnsupportedJSONPathsCannotEvaluateExpressionsOrZipSeparateArrays() throws {
        for bad in ["$.data[?(@.admin)].name", "$..title", "$.rows[*].nested[*].name", "$.rows[0].title", "$.rows[*]['a','b'].name"] {
            XCTAssertThrowsError(try SearchJSONPath.compile(bad))
        }
        let config: [String: Any] = ["searchUrl": "https://catalog.example/api?q={keyword}", "subjectFormatId": "json-path-indexed",
            "selectorSubjectFormatJsonPathIndexed": ["selectNames": "$.names[*].title", "selectLinks": "$.links[*].url"]]
        XCTAssertThrowsError(try SourceSubscriptionConverter.convertSearch(config: config, baseline: baseline()))
    }

    func testUntrustedURLsAndAmbiguousHostOwnershipAreRejected() throws {
        for raw in ["http://catalog.example?q={keyword}", "https://user:secret@catalog.example?q={keyword}",
                    "https://catalog.example?q={keyword}&token=secret", "https://catalog.example?q={keyword}&q=duplicate",
                    "https://catalog.example?q={unknown}", "https://catalog.example?q={query}&other={keyword}",
                    "https://catalog.example:8443?q={keyword}", "https://catalog.example.evil.test?q={keyword}",
                    "https://catalog.example?{keyword}=value", "https://catalog.example?q={keyword}#fragment"] {
            var config = indexed(); config["searchUrl"] = raw
            XCTAssertThrowsError(try SourceSubscriptionConverter.convertSearch(config: config, baseline: baseline()), raw)
        }
        let local = try baseline()
        let ambiguous = try SourceSubscriptionConverter.convert(data: feed([indexed()]), baselines: ["first": local, "second": local], installed: [:], names: [:])
        XCTAssertTrue(ambiguous.overrides.isEmpty)
        var nativeConfig = indexed(); nativeConfig["searchUrl"] = "https://www.jibi.cc/search?q={keyword}"
        let spoof = try baseline(hosts: ["www.jibi.cc"])
        let rejected = try SourceSubscriptionConverter.convert(data: feed([nativeConfig]), baselines: ["custom": spoof], installed: [:], names: [:])
        XCTAssertTrue(rejected.overrides.isEmpty)
        let nativeID = try SourceSubscriptionConverter.convert(data: feed([indexed()]), baselines: ["jibi": local], installed: [:], names: [:])
        XCTAssertTrue(nativeID.overrides.isEmpty)
    }

    func testAbsentPaginationDoesNotFabricateQueryAndPageOnlyStillAddsQuery() throws {
        let generic = try SourceSubscriptionConverter.searchSource(config: indexed(), hosts: ["catalog.example"])
        let url = try SourceSearchExecutor.requestURL(generic.search, query: "test", page: 1, allowedHosts: ["catalog.example"])
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name), ["kind"])
        let data = Data(#"{"url":"https://catalog.example/search?page={page}","format":"html","queryParameter":"q","pageParameter":"page","rowsPerPage":20}"#.utf8)
        let pageOnly = try JSONDecoder().decode(SourceConfiguration.Search.self, from: data)
        let address = try SourceSearchExecutor.requestURL(pageOnly, query: "One & Two", page: 2, allowedHosts: ["catalog.example"])
        XCTAssertEqual(URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value, "One & Two")
    }

    func testGenericPaginationUsesExplicitPageSizeAndRequiresAChangingRequest() throws {
        var config = indexed()
        config["searchUrl"] = "https://catalog.example/search?q={keyword}&pagesize=24&pageindex={page}"
        let source = try SourceSubscriptionConverter.searchSource(config: config, hosts: ["catalog.example"])
        XCTAssertEqual(source.search.rowsPerPage, 24)
        let html = (1...24).map { "<article><span class=name>Title \($0)</span><a class=result href='/work/\($0)'></a></article>" }.joined()
        XCTAssertEqual(try parse(html, source: source).nextPage, 2)
        let url = try SourceSearchExecutor.requestURL(source.search, query: "title", page: 2, allowedHosts: ["catalog.example"])
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "pageindex" }?.value, "2")

        config["searchUrl"] = "https://catalog.example/search?q={keyword}&pagesize=24"
        let single = try SourceSubscriptionConverter.searchSource(config: config, hosts: ["catalog.example"])
        XCTAssertNil(try parse(html, source: single).nextPage)
        config["searchUrl"] = "https://catalog.example/search?q={keyword}&pagesize=12&pageindex={page}"
        let reviewed = try SourceSubscriptionConverter.searchSource(config: config, hosts: ["catalog.example"], baseline: baseline())
        XCTAssertEqual(reviewed.search.rowsPerPage, 24) // Existing native pagination remains authoritative.
        config["searchUrl"] = "https://catalog.example/search?q={keyword}&pagesize=24&limit=12&pageindex={page}"
        XCTAssertThrowsError(try SourceSubscriptionConverter.searchSource(config: config, hosts: ["catalog.example"]))
    }

    func testCredentialAndPlayerFieldsAreNeverCopiedAndConflictsRejectAllDuplicates() throws {
        var config = indexed(); config["cookies"] = "secret-cookie"; config["script"] = "secret-script"
        config["matchVideo"] = ["url": "secret-player"]
        let local = try baseline()
        let converted = try SourceSubscriptionConverter.convertSearch(config: config, baseline: local)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(converted), as: UTF8.self).contains("secret-"))
        var other = config; other["selectorSubjectFormatIndexed"] = ["selectNames": ".different", "selectLinks": ".different"]
        for entries in [[config, other], [other, config]] {
            let plan = try SourceSubscriptionConverter.convert(data: feed(entries), baselines: ["custom": local], installed: [:], names: [:])
            XCTAssertNil(plan.overrides["custom"])
        }
    }

    func testUnknownOriginCreatesExplicitV4ConfigurationWithoutNativeIdentity() throws {
        let plan = try SourceSubscriptionConverter.convert(data: feed([staticConfig()]), baselines: [:], installed: [:], names: [:])
        XCTAssertTrue(plan.overrides.isEmpty)
        let encoded = try XCTUnwrap(plan.configurations.values.first)
        let config = try SourceConfiguration.load(data: encoded)
        XCTAssertEqual(config.version, 4)
        XCTAssertTrue(config.id.hasPrefix("web-"))
        XCTAssertEqual(config.hosts, ["catalog.example"])
        XCTAssertEqual(config.search?.resultsSelector, "a.result")
        XCTAssertEqual(config.webSelector?.episodeNames, "a")
        XCTAssertTrue(config.effectiveCapabilities(on: .macOS).contains(.resolve))
        XCTAssertTrue(config.effectiveCapabilities(on: .iOS).contains(.resolve))
        let next = try SourceSubscriptionConverter.convert(data: feed([staticConfig()]), baselines: [:], installed: [:], names: [:])
        XCTAssertEqual(next.configurations, plan.configurations)
    }

    func testGenericConfigurationCannotAcquireNativeOrInstalledHost() throws {
        let native = try SourceSubscriptionConverter.convert(data: feed([staticConfig("www.jibi.cc")]), baselines: [:], installed: [:], names: [:])
        XCTAssertTrue(native.configurations.isEmpty)
        let local = try baseline()
        let installed = try SourceSubscriptionConverter.convert(data: feed([staticConfig()]), baselines: ["custom": local], installed: [:], names: [:])
        XCTAssertTrue(installed.configurations.isEmpty)
        XCTAssertNotNil(installed.overrides["custom"])
    }

    func testConflictingGenericOriginAndInvalidDuplicateCannotPartiallyReplaceSource() throws {
        let valid = staticConfig()
        var changed = valid
        changed["selectorChannelFormatFlattened"] = ["selectChannelNames": ".other", "selectEpisodeLists": ".other", "selectEpisodesFromList": "a"]
        var malformed = valid
        malformed["selectorChannelFormatFlattened"] = ["selectEpisodeLists": "a[", "selectEpisodesFromList": "a"]
        for entries in [[valid, changed], [changed, valid], [valid, malformed], [malformed, valid]] {
            let plan = try SourceSubscriptionConverter.convert(data: feed(entries), baselines: [:], installed: [:], names: [:])
            XCTAssertTrue(plan.configurations.isEmpty)
        }
        let identical = try SourceSubscriptionConverter.convert(data: feed([valid, valid]), baselines: [:], installed: [:], names: [:])
        XCTAssertEqual(identical.configurations.count, 1)
    }

    func testLegacyV3RemainsInactiveInsteadOfSilentlyUpgradingSavedRules() throws {
        let plan = try SourceSubscriptionConverter.convert(data: feed([staticConfig()]), baselines: [:], installed: [:], names: [:])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(plan.configurations.values.first)) as? [String: Any])
        object["version"] = 3
        object["capabilities"] = ["information", "search", "episodes", "lines", "resolve", "mpv"]
        object["search"] = ["url": "https://catalog.example/search?q={query}", "format": "web-selector", "queryParameter": "", "pageParameter": "", "rowsPerPage": 100]
        let legacy = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(RuntimeSource.configured(legacy).effectiveCapabilities(on: .iOS).isEmpty)
        XCTAssertTrue(RuntimeSource.configured(legacy).effectiveCapabilities(on: .macOS).isEmpty)
        XCTAssertThrowsError(try RuntimeSource.configured(legacy).item("https://catalog.example/work/1"))
    }

    func testPersistedSearchValidationChecksTemplatesAndParserShapesWithoutNetwork() throws {
        let source = try SourceSubscriptionConverter.searchSource(config: indexed(), hosts: ["catalog.example"])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source.search)) as? [String: Any])
        for change: [String: Any] in [["resultBaseURL": "https://outside.example/"],
                                     ["resultURLTemplate": "https://catalog.example/work/{unknown}"],
                                     ["resultURLTemplate": "https://catalog.example/work/{value}?token=secret"],
                                     ["url": "https://catalog.example/search?q={query}&authorization=secret"],
                                     ["indexedLinksSelector": "a["],
                                     ["resultsSelector": "a.result", "titleSelector": "self"]] {
            let data = try JSONSerialization.data(withJSONObject: original.merging(change) { _, new in new })
            let spec = try JSONDecoder().decode(SourceConfiguration.Search.self, from: data)
            XCTAssertThrowsError(try SourceSearchExecutor.validate(spec, allowedHosts: ["catalog.example"]))
        }
    }

    func testLegacyFixedArrayQueryParametersRemainExplicitAndPreserveValues() throws {
        let source = try SourceSubscriptionConverter.searchSource(config: indexed(), hosts: ["catalog.example"])
        var original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(source.search)) as? [String: Any])
        func spec(_ url: String) throws -> SourceConfiguration.Search {
            original["url"] = url
            return try JSONDecoder().decode(SourceConfiguration.Search.self, from: JSONSerialization.data(withJSONObject: original))
        }
        let legacy = try spec("https://catalog.example/api?q={query}&fl%5B%5D=identifier&fl%5B%5D=title")
        XCTAssertThrowsError(try SourceSearchExecutor.validate(legacy, allowedHosts: ["catalog.example"]))
        try SourceSearchExecutor.validate(legacy, allowedHosts: ["catalog.example"], allowLegacyArrayQueryParameters: true)
        let url = try SourceSearchExecutor.requestURL(legacy, query: "A & B", page: 1, allowedHosts: ["catalog.example"])
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "fl[]" }.compactMap(\.value), ["identifier", "title"])
        for raw in ["https://catalog.example/api?q={query}&q=fixed",
                    "https://catalog.example/api?q%5B%5D={query}&q%5B%5D=fixed",
                    "https://catalog.example/api?q={query}&token%5B%5D=a&token%5B%5D=b"] {
            XCTAssertThrowsError(try SourceSearchExecutor.validate(spec(raw), allowedHosts: ["catalog.example"], allowLegacyArrayQueryParameters: true))
        }
    }
}
