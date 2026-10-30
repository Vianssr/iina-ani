import Foundation

@MainActor enum MobileCSS1Regression {
    static func run(root: URL) throws {
        let anchor = item(id: "standalone-a", name: "Independent source")
        var indexedSearch = search(anchor)
        indexedSearch["subjectFormatId"] = "indexed"
        indexedSearch["selectorSubjectFormatIndexed"] = ["selectNames": ".name", "selectLinks": ".link a"]
        let indexed = replacingSearch(item(id: "standalone-indexed"), indexedSearch)
        var jsonSearch = search(anchor)
        jsonSearch["subjectFormatId"] = "json-path-indexed"
        jsonSearch["searchUrl"] = "https://api.example/search?word={keyword}"
        jsonSearch["rawBaseUrl"] = "https://video.example"
        jsonSearch["selectorSubjectFormatJsonPathIndexed"] = ["selectNames": "$.info.rows[*].name", "selectLinks": "$.info.rows[*]['id']", "linkTemplate": "/watch/{value}"]
        let json = replacingSearch(item(id: "standalone-json"), jsonSearch)
        var groupedSearch = search(anchor)
        groupedSearch["channelFormatId"] = "index-grouped"
        groupedSearch["selectorChannelFormatFlattened"] = ["selectChannelNames": ".tabs span", "selectEpisodeLists": ".episodes", "selectEpisodesFromList": "a span", "selectEpisodeLinksFromList": "a"]
        let grouped = replacingSearch(item(id: "standalone-grouped"), groupedSearch)
        let batch = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [anchor, indexed, json, grouped]]))
        precondition(batch.drafts.map { $0.configuration.id } == ["standalone-a", "standalone-indexed", "standalone-json", "standalone-grouped"])
        precondition(batch.drafts.allSatisfy { $0.configuration.version == 3 && $0.configuration.webSelector != nil })
        precondition(batch.drafts[0].configuration.webSelector?.episodeLists == nil)
        precondition(batch.drafts[2].configuration.hosts == ["api.example", "video.example"])
        precondition(batch.drafts[2].configuration.webSelector?.baseURL == "https://video.example")
        precondition(batch.drafts[2].configuration.webSelector?.linkTemplate == "/watch/{value}")
        precondition(batch.drafts[3].configuration.webSelector?.episodeLinks == "a")
        precondition(batch.notices.isEmpty)

        let preferred = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [anchor],
            "exportedMediaSourceDataList": ["mediaSources": [indexed]]]))
        precondition(preferred.drafts.map { $0.configuration.id } == ["standalone-a"])
        let nested = try MobileCSS1Configuration.convert(data: encode(["exportedMediaSourceDataList": ["mediaSources": [indexed]]]))
        precondition(nested.drafts.map { $0.configuration.id } == ["standalone-indexed"])
        rejects { try MobileCSS1Configuration.convert(data: encode(["mediaSources": [], "exportedMediaSourceDataList": ["mediaSources": [indexed]]])) }
        rejects { try MobileCSS1Configuration.convert(data: encode(["mediaSources": NSNull(), "exportedMediaSourceDataList": ["mediaSources": [indexed]]])) }
        rejects { try MobileCSS1Configuration.convert(data: encode(["mediaSources": [anchor, anchor]])) }

        var unnamedID = anchor
        unnamedID.removeValue(forKey: "id")
        let fallback = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [unnamedID]])).drafts[0]
        let fallbackAgain = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [unnamedID]], sorted: true)).drafts[0]
        precondition(fallback.configuration.id.hasPrefix("css1-") && fallback.configuration.id == fallbackAgain.configuration.id)
        unnamedID["id"] = "../invalid/id"
        let repairedID = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [unnamedID]])).drafts[0]
        precondition(repairedID.configuration.id == fallback.configuration.id)

        var privateSearch = search(anchor)
        privateSearch["cookies"] = "fixture-private-cookie"
        privateSearch["headers"] = ["Authorization": "fixture-private-header"]
        privateSearch["matchVideo"] = ["cookies": "fixture-nested-cookie", "addHeadersToVideo": ["referer": "fixture-header"], "matchVideoUrl": "fixture-remote-expression"]
        let sanitized = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [replacingSearch(anchor, privateSearch)]])).drafts[0]
        let saved = String(decoding: sanitized.data, as: UTF8.self)
        for omitted in ["cookies", "headers", "matchVideo", "fixture-private", "fixture-nested", "fixture-remote-expression"] {
            precondition(!saved.contains(omitted), "Remote request credentials or expressions persisted")
        }
        precondition(sanitized.configuration.credentialHosts.isEmpty)

        var unsupported = item(id: "other-parser")
        unsupported["factoryId"] = "json-api"
        var insecure = search(anchor)
        insecure["searchUrl"] = "http://plain.example/search?wd={keyword}"
        let partial = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [anchor, unsupported,
            replacingSearch(item(id: "insecure"), insecure)]]))
        precondition(partial.drafts.count == 1 && partial.notices.count == 2)
        precondition(partial.notices[0].contains("Unsupported parser type"))
        precondition(partial.notices[1].contains("HTTPS is required"))
        let allUnsupported = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [unsupported,
            replacingSearch(item(id: "insecure"), insecure)]]))
        precondition(allUnsupported.drafts.isEmpty && allUnsupported.notices.count == 2)
        for address in ["https://user:fixture@video.example/search?wd={keyword}",
                        "https://video.example:443/search?wd={keyword}",
                        "https://video.example/search?wd={keyword}&token=fixture",
                        "https://video.example/search?wd={keyword}#fragment",
                        "https://video.example/search?wd={keyword}&other={unknown}"] {
            var invalid = search(anchor)
            invalid["searchUrl"] = address
            try unusable([replacingSearch(anchor, invalid)])
        }
        var pathSearch = search(anchor)
        pathSearch["searchUrl"] = "https://video.example/search/{keyword}/page.html"
        let pathDraft = try MobileCSS1Configuration.convert(data: encode(["mediaSources": [replacingSearch(anchor, pathSearch)]])).drafts[0]
        precondition(pathDraft.configuration.search?.url == "https://video.example/search/{query}/page.html")
        for path in ["$.rows[*].name", "$['rows'][*]['name']", "$[*].name"] {
            precondition(tryPath(path) == path)
        }
        for path in ["$..name", "$.rows[?(@.enabled)].name", "$.rows[*]['name','title']", "$.rows[0].name", "$.rows[*]"] {
            rejects { try MobileCSS1Configuration.jsonPath(path) }
        }
        var invalidSelector = search(anchor)
        invalidSelector["selectorSubjectFormatA"] = ["selectLists": "a["]
        try unusable([replacingSearch(anchor, invalidSelector)])
        invalidSelector["selectorSubjectFormatA"] = ["selectLists": String(repeating: "a", count: 1025)]
        try unusable([replacingSearch(anchor, invalidSelector)])
        try sampleIfAvailable(root)
        print("PASS: independent CSS1 sources, supported selectors, JSONPath subset, URL restrictions, sanitized persistence, stable identity and unsupported-entry notices")
    }

    private static func sampleIfAvailable(_ root: URL) throws {
        let sample = root.appendingPathComponent(".build/mobile-default-subscription/css1.json")
        guard FileManager.default.fileExists(atPath: sample.path) else {
            print("SKIP: optional downloaded CSS1 sample is unavailable; synthetic converter regression completed")
            return
        }
        let data = try Data(contentsOf: sample)
        let batch = try MobileCSS1Configuration.convert(data: data)
        precondition(batch.drafts.count == 18 && batch.notices.count == 2, "Downloaded CSS1 sample did not yield its 18 supported HTTPS web-selector sources")
        precondition(batch.drafts.contains { $0.configuration.id == "fanqie-dongman" })
        precondition(!batch.drafts.contains { $0.configuration.id == "fqdm" }, "CSS1 identity was remapped to a bundled source")
        print("PASS: downloaded CSS1 sample converts 18 independent sources; 2 unsupported entries are reported")
    }

    private static func item(id: String = "standalone-a", name: String = "Source fixture") -> [String: Any] {
        ["id": id, "factoryId": "web-selector", "version": 2, "arguments": ["name": name, "searchConfig": [
            "searchUrl": "https://video.example/search?wd={keyword}", "subjectFormatId": "a",
            "selectorSubjectFormatA": ["selectLists": ".results a"], "channelFormatId": "no-channel",
            "selectorChannelFormatNoChannel": ["selectEpisodes": ".episodes a"]]]]
    }
    private static func search(_ item: [String: Any]) -> [String: Any] {
        (item["arguments"] as! [String: Any])["searchConfig"] as! [String: Any]
    }
    private static func replacingSearch(_ item: [String: Any], _ search: [String: Any]) -> [String: Any] {
        var item = item
        var arguments = item["arguments"] as! [String: Any]
        arguments["searchConfig"] = search
        item["arguments"] = arguments
        return item
    }
    private static func encode(_ value: Any, sorted: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: sorted ? [.sortedKeys] : [])
    }
    private static func tryPath(_ value: String) -> String { try! MobileCSS1Configuration.jsonPath(value) }
    private static func unusable(_ items: [[String: Any]]) throws {
        let batch = try MobileCSS1Configuration.convert(data: encode(["mediaSources": items]))
        precondition(batch.drafts.isEmpty && batch.notices.count == items.count)
    }
    private static func rejects<T>(_ operation: () throws -> T) {
        do { _ = try operation(); preconditionFailure("Unsupported CSS1 configuration accepted") } catch {}
    }
}
