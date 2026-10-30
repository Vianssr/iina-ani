import Foundation

@MainActor enum CSS1IdentityRegression {
    static func run(root: URL) async throws {
        let configuration = try fixture()
        try canonicalPages(configuration)
        try credentialValidation(configuration)
        try selectionIdentity(configuration)
        try revisionCompatibility(configuration, root: root)
        print("PASS: CSS1 canonical public-page identity, host/source/work isolation, duplicate selection rejection, credential refusal and native revision compatibility")
    }

    private static func fixture() throws -> SourceConfiguration {
        let item: [String: Any] = ["id": "css1-identity-fixture", "factoryId": "web-selector", "version": 2,
            "arguments": ["name": "CSS1 identity fixture", "searchConfig": [
                "searchUrl": "https://identity.example/search?wd={keyword}",
                "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": "a.result"],
                "channelFormatId": "index-grouped", "selectorChannelFormatFlattened": [
                    "selectChannelNames": ".line-title", "selectEpisodeLists": ".episodes",
                    "selectEpisodesFromList": "a", "selectEpisodeLinksFromList": ""
                ]
            ]]]
        let data = try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
        let converted = try MobileCSS1Configuration.convert(data: data)
        precondition(converted.drafts.count == 1)
        return converted.drafts[0].configuration
    }

    private static func canonicalPages(_ configuration: SourceConfiguration) throws {
        let first = try configuration.webItem("https://IDENTITY.example/watch?id=1#chapter", kind: .episode)
        precondition(first.pageURL == "https://identity.example/watch?id=1")
        precondition(first.kind == .episode && first.sourceID == configuration.id)
        let second = try configuration.webItem("https://identity.example/watch?id=2", kind: .episode)
        precondition(first != second)
        let upperPath = try configuration.webItem("https://identity.example/Watch/1", kind: .episode)
        let lowerPath = try configuration.webItem("https://identity.example/watch/1", kind: .episode)
        precondition(upperPath != lowerPath)
        let encodedSlash = try configuration.webItem("https://identity.example/watch/a%2Fb", kind: .episode)
        let slash = try configuration.webItem("https://identity.example/watch/a/b", kind: .episode)
        precondition(encodedSlash != slash)
        for invalid in ["https://other.example/watch/1", "http://identity.example/watch/1",
                        "https://user:fixture@identity.example/watch/1", "https://identity.example:8443/watch/1",
                        "https://identity.example/watch?token=fixture", "https://identity.example/watch?utm_source=fixture",
                        "https://identity.example/watch?id=1&episode=2", "https://identity.example/watch?id=1&id=2",
                        "https://identity.example/watch?url=https://other.example/a", "https://identity.example/video.m3u8"] {
            rejects { _ = try configuration.webItem(invalid, kind: .episode) }
        }
    }

    private static func credentialValidation(_ configuration: SourceConfiguration) throws {
        let original = try JSONSerialization.jsonObject(with: configuration.encodedData()) as! [String: Any]
        for name in ["token", "cookie", "access_token", "authorization", "auth", "api_key"] {
            var object = original
            var search = object["search"] as! [String: Any]
            search["url"] = "https://identity.example/search?wd={query}&\(name)=fixture"
            object["search"] = search
            let body = try JSONSerialization.data(withJSONObject: object)
            rejects { _ = try SourceConfiguration.load(data: body) }
            object = original
            var selector = object["webSelector"] as! [String: Any]
            selector["baseURL"] = "https://identity.example/?\(name)=fixture"
            object["webSelector"] = selector
            let baseBody = try JSONSerialization.data(withJSONObject: object)
            rejects { _ = try SourceConfiguration.load(data: baseBody) }
        }
        for section in ["route", "catalog", "player", "webSelector"] {
            var object = original
            var fields = object[section] as! [String: Any]
            let key = ["route": "detailTemplate", "catalog": "url", "player": "streamURLTemplate", "webSelector": "linkTemplate"][section]!
            fields[key] = "https://identity.example/file?token=fixture&value={value}"
            object[section] = fields
            let body = try JSONSerialization.data(withJSONObject: object)
            rejects { _ = try SourceConfiguration.load(data: body) }
        }
        var object = original
        var search = object["search"] as! [String: Any]
        search["url"] = "https://identity.example/search?wd={query}&page={unknown}"
        object["search"] = search
        let unresolved = try JSONSerialization.data(withJSONObject: object)
        rejects { _ = try SourceConfiguration.load(data: unresolved) }
    }

    private static func selectionIdentity(_ configuration: SourceConfiguration) throws {
        let client = MobileSourceClient(configuration: configuration)
        let work = MobileSourceWork(item: try configuration.webItem("https://identity.example/anime/one", kind: .work), title: "Same title")
        let otherWork = MobileSourceWork(item: try configuration.webItem("https://identity.example/anime/two", kind: .work), title: "Same title")
        func episode(_ page: String, line: Int = 1, number: Int = 1) throws -> MobileSourceEpisode {
            let item = try configuration.webItem("https://identity.example/" + page, kind: .episode)
            return MobileSourceEpisode(item: item, title: "Episode 1", line: line, number: number, identity: item.pageURL)
        }
        let first = try episode("watch?id=1")
        let second = try episode("watch?id=2", number: 2)
        let catalog = MobileSourceCatalog(work: work, lines: [.init(id: 1, title: "Line", episodes: [first, second])])
        let context = try client.playbackContext(first, in: catalog, requestedWork: nil, requestedEpisode: nil)
        precondition(context.configurationRevision == configuration.configurationRevision)
        precondition(context.selection.item == work.item && context.selection.episode == first.item)
        try ConfirmedSourceMapping(context: context, sourceTitle: "Identity fixture").validateForPersistence()
        let matched = try client.episode(matching: context.selection, in: catalog)
        let next = try client.nextEpisode(after: context.selection, in: catalog)
        precondition(matched.item == first.item && next?.item == second.item)

        let otherCatalog = MobileSourceCatalog(work: otherWork, lines: [.init(id: 1, title: "Line", episodes: [second])])
        rejects { _ = try client.playbackContext(first, in: otherCatalog, requestedWork: nil, requestedEpisode: nil) }
        rejects { _ = try client.episode(matching: context.selection, in: otherCatalog) }
        let missing = MobileSourceCatalog(work: work, lines: [.init(id: 1, title: "Line", episodes: [second])])
        rejects { _ = try client.episode(matching: context.selection, in: missing) }

        var differentSource = context.selection
        differentSource.episode = SourceItemRef(sourceID: "another-source", pageURL: first.item.pageURL, kind: .episode)
        rejects { _ = try configuration.mappingSelection(differentSource) }
        let duplicate = MobileSourceCatalog(work: work, lines: [.init(id: 1, title: "Line", episodes: [first, first, second])])
        rejects { _ = try client.episode(matching: context.selection, in: duplicate) }
        rejects { _ = try client.nextEpisode(after: context.selection, in: duplicate) }

        let sameNumber = try episode("watch?id=3")
        let ambiguousNumber = MobileSourceCatalog(work: work, lines: [.init(id: 1, title: "Line", episodes: [first, sameNumber])])
        let distinct = try client.playbackContext(sameNumber, in: ambiguousNumber, requestedWork: nil, requestedEpisode: nil)
        precondition(context.episode != distinct.episode)
        rejects { _ = try client.nextEpisode(after: context.selection, in: ambiguousNumber) }

        let moved = try episode("watch?id=1", line: 2)
        let changedLines = MobileSourceCatalog(work: work, lines: [.init(id: 2, title: "Line", episodes: [moved])])
        rejects { _ = try client.episode(matching: context.selection, in: changedLines) }
        // The same episode URL in a different work still has a different source-work identity.
        let copied = MobileSourceCatalog(work: otherWork, lines: [.init(id: 1, title: "Line", episodes: [first])])
        let copiedContext = try client.playbackContext(first, in: copied, requestedWork: nil, requestedEpisode: nil)
        precondition(copiedContext.work != context.work && copiedContext.episode != context.episode)
    }

    private static func revisionCompatibility(_ configuration: SourceConfiguration, root: URL) throws {
        let encoded = try configuration.encodedData()
        let reopened = try SourceConfiguration.load(data: encoded)
        precondition(reopened.configurationRevision == configuration.configurationRevision)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var selector = object["webSelector"] as! [String: Any]
        selector["episodeNames"] = "a.updated-episode"
        object["webSelector"] = selector
        let changed = try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object))
        precondition(changed.configurationRevision != configuration.configurationRevision)
        let native = try SourceConfiguration.load(fileURL: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let nativeEncoded = try native.encodedData()
        let nativeObject = try JSONSerialization.jsonObject(with: nativeEncoded) as! [String: Any]
        precondition(nativeObject["webSelector"] == nil && native.webSelector == nil)
        let nativeReopened = try SourceConfiguration.load(data: nativeEncoded)
        precondition(nativeReopened.configurationRevision == native.configurationRevision)
        precondition(native.effectiveCapabilities(on: .iOS).contains(.resolve))
        precondition(configuration.effectiveCapabilities(on: .macOS).isEmpty)
    }

    private static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Invalid CSS1 identity/configuration accepted") }
        catch {}
    }
}
