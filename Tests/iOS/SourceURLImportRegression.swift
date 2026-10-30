import Foundation

private actor ConfigurationDownloadGate {
    private var continuation: CheckedContinuation<Data, Never>?
    private let data: Data
    var waiting: Bool { continuation != nil }
    init(_ data: Data) { self.data = data }
    func fetch() async -> Data { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(returning: data); continuation = nil }
}

@MainActor enum SourceURLImportRegression {
    static func run(root: URL) async throws {
        for invalid in ["", "https://", "http://config.example/source.json", "file:///tmp/source.json",
                        "javascript:alert(1)", "https://user:password@config.example/source.json",
                        "https://config.example/source.json#fragment", "https://config.example/a b.json"] {
            precondition(MobileSourceImportTransport.parse(invalid) == nil)
        }
        let url = MobileSourceImportTransport.parse(" \nhttps://config.example/source.json?version=1 \n")!
        precondition(url.host == "config.example")
        let request = MobileSourceImportTransport.anonymousRequest(url)
        precondition(request.httpShouldHandleCookies == false)
        precondition(request.value(forHTTPHeaderField: "Cookie") == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")

        // Redirect requests are rebuilt, including redirects to a second HTTPS host.
        let delegate = MobileSourceImportTransport()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: url)
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
        var redirected = URLRequest(url: URL(string: "https://cdn.example/source.json")!)
        redirected.setValue("secret", forHTTPHeaderField: "Cookie")
        redirected.setValue("secret", forHTTPHeaderField: "Authorization")
        redirected.setValue("secret", forHTTPHeaderField: "Proxy-Authorization")
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: redirected) { cleaned in
            precondition(cleaned?.url?.host == "cdn.example")
            precondition(cleaned?.httpShouldHandleCookies == false)
            for name in ["Cookie", "Authorization", "Proxy-Authorization"] {
                precondition(cleaned?.value(forHTTPHeaderField: name) == nil)
            }
        }
        for invalid in ["http://cdn.example/source.json", "https://user:secret@cdn.example/source.json"] {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: redirect,
                                newRequest: URLRequest(url: URL(string: invalid)!)) { precondition($0 == nil) }
        }

        let data = try Data(contentsOf: root.appendingPathComponent("IINA-ANI/Sources/fqdm.json"))
        let config = try MobileSourceLibrary.validate(data)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = MobileSourceLibrary(directory: directory, bundled: { [] })
        let importer = MobileSourceURLImport { _ in data }
        importer.load(url.absoluteString)
        await idle(importer)
        precondition(importer.failure == nil && importer.draft?.configuration.id == config.id)
        precondition(library.sources.isEmpty && !FileManager.default.fileExists(atPath: directory.path))
        let draft = importer.draft!
        try library.apply(draft)
        precondition(library.sources.map(\.id) == [config.id])
        precondition(!UserDefaults.standard.bool(forKey: "mobile.sources." + config.id + ".enabled"))
        precondition(MobileSourceLibrary(directory: directory, bundled: { [] }).replaces(draft))
        let before = try Data(contentsOf: directory.appendingPathComponent(config.id + ".json"))

        for bad in [Data("<html>not JSON</html>".utf8), Data(repeating: 32, count: MobileSourceImportTransport.maximumBytes + 1)] {
            let invalid = MobileSourceURLImport { _ in bad }
            invalid.load(url.absoluteString)
            await idle(invalid)
            precondition(invalid.draft == nil)
            guard case .invalidConfiguration? = invalid.failure else { fatalError("Missing configuration validation failure") }
        }
        let failing = MobileSourceURLImport(fetch: { _ in throw URLError(.timedOut) })
        failing.load(url.absoluteString)
        await idle(failing)
        guard case .download? = failing.failure else { fatalError("Missing retryable download failure") }
        let unchanged = try Data(contentsOf: directory.appendingPathComponent(config.id + ".json"))
        precondition(unchanged == before)

        // Cancelling or entering a different URL invalidates even a transport ignoring cancellation.
        for replace in [false, true] {
            let gate = ConfigurationDownloadGate(data)
            let pending = MobileSourceURLImport { _ in await gate.fetch() }
            pending.load(url.absoluteString)
            while !(await gate.waiting) { await Task.yield() }
            if replace { pending.load("invalid") } else { pending.cancel() }
            await gate.release()
            for _ in 0..<100 { await Task.yield() }
            precondition(!pending.busy && pending.draft == nil)
            if replace {
                guard case .invalidAddress? = pending.failure else { fatalError("Stale download replaced current error") }
            } else { precondition(pending.failure == nil) }
        }
        try await formats(data: data, root: directory)
        try await subscriptions(data: data, root: directory)
        print("PASS: URL configuration review/commit separation, validation, anonymous HTTPS redirects, failure preservation and stale/cancelled downloads")
    }

    private static func formats(data: Data, root: URL) async throws {
        let original = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var second = original
        second["id"] = "import-second"
        let secondData = try JSONSerialization.data(withJSONObject: second)
        let base = URL(string: "https://config.example/folder/list.json?revision=2")!
        for body in [try JSONSerialization.data(withJSONObject: [original, second]),
                     try JSONSerialization.data(withJSONObject: ["version": 1, "sources": [original, second]])] {
            let importer = MobileSourceURLImport { _ in body }
            importer.load(base.absoluteString)
            await idle(importer)
            precondition(importer.draft == nil && importer.subscriptionPreview == nil && importer.failure == nil,
                         "List preview failed: \(String(describing: importer.failure)), root byte \(body.first ?? 0)")
            precondition(importer.batch?.drafts.map(\.configuration.id) == ["fqdm", "import-second"])
            importer.clearPreview()
            precondition(importer.batch == nil)
        }
        var nativeWithExtra = original
        nativeWithExtra["sources"] = ["https://never.example/source.json"]
        let nativeBody = try JSONSerialization.data(withJSONObject: nativeWithExtra)
        let single = MobileSourceURLImport { _ in nativeBody }
        single.load(base.absoluteString)
        await idle(single)
        precondition(single.draft == nil && single.batch == nil)
        guard case .invalidConfiguration? = single.failure else { fatalError("Unknown native keys became a manifest") }

        let manifest = try JSONSerialization.data(withJSONObject: ["version": 1,
            "sources": ["first.json?version=3", "https://other.example/second.json"]])
        let redirectedBase = URL(string: "https://cdn.example/export/list.json")!
        let references = MobileSourceURLImport(fetchResponse: { url in
            if url == base { return .init(data: manifest, url: redirectedBase) }
            if url.absoluteString == "https://cdn.example/export/first.json?version=3" { return .init(data: data, url: url) }
            if url.absoluteString == "https://other.example/second.json" { return .init(data: secondData, url: url) }
            preconditionFailure("Relative reference did not use final response URL")
        })
        references.load(base.absoluteString)
        await idle(references)
        precondition(references.batch?.drafts.count == 2)

        let rejected: [Any] = [[], [original, original], [original, "http://other.example/source.json"],
            [original, "https://user:secret@other.example/source.json"], [original, 7],
            ["version": 2, "sources": [original]], ["version": true, "sources": [original]],
            ["sources": [original]], ["version": 1, "sources": Array(repeating: original, count: 101)]]
        for object in rejected {
            let body = try JSONSerialization.data(withJSONObject: object)
            let importer = MobileSourceURLImport { _ in body }
            importer.load(base.absoluteString)
            await idle(importer)
            precondition(importer.draft == nil && importer.batch == nil && importer.subscriptionPreview == nil)
            guard case .invalidConfiguration? = importer.failure else { fatalError("Malformed list accepted") }
        }
        let partialBody = try JSONSerialization.data(withJSONObject: [original, "https://other.example/missing.json"])
        let partial = MobileSourceURLImport { url in
            if url == base { return partialBody }
            throw URLError(.fileDoesNotExist)
        }
        partial.load(base.absoluteString)
        await idle(partial)
        precondition(partial.batch == nil && partial.draft == nil)
        guard case .download? = partial.failure else { fatalError("Partial download exposed a preview") }

        let gate = ConfigurationDownloadGate(secondData)
        let pending = MobileSourceURLImport { url in
            if url == base { return partialBody }
            return await gate.fetch()
        }
        pending.load(base.absoluteString)
        while !(await gate.waiting) { await Task.yield() }
        pending.cancel()
        await gate.release()
        for _ in 0..<100 { await Task.yield() }
        precondition(pending.batch == nil && pending.draft == nil && pending.failure == nil)

        var oversized = original
        oversized["name"] = String(repeating: "x", count: 1024 * 1024)
        let oversizedData = try JSONSerialization.data(withJSONObject: oversized)
        precondition(oversizedData.count < MobileSourceImportTransport.maximumBytes)
        let tooLarge = MobileSourceURLImport { _ in oversizedData }
        tooLarge.load(base.absoluteString)
        await idle(tooLarge)
        guard case .invalidConfiguration? = tooLarge.failure else { fatalError("Native config exceeded 1 MiB") }

        var padded: [String: Data] = [:]
        for index in 0..<20 {
            var entry = original
            entry["id"] = "limit-\(index)"
            entry["name"] = String(repeating: "x", count: 900_000)
            padded["https://config.example/\(index).json"] = try JSONSerialization.data(withJSONObject: entry)
        }
        let payloads = padded
        let many = try JSONSerialization.data(withJSONObject: payloads.keys.sorted())
        let total = MobileSourceURLImport { url in url == base ? many : payloads[url.absoluteString]! }
        total.load(base.absoluteString)
        await idle(total)
        precondition(total.batch == nil)
        guard case .invalidConfiguration? = total.failure else { fatalError("Aggregate download limit was ignored") }
        print("PASS: native single/list formats, final-URL relative references, duplicates/limits and no partial or cancelled batch preview")
    }

    private static func subscriptions(data: Data, root: URL) async throws {
        var custom = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        custom["id"] = "custom-source"
        let replaced = String(decoding: try JSONSerialization.data(withJSONObject: custom), as: UTF8.self)
            .replacingOccurrences(of: "fqdm.cc", with: "custom.example")
        let baseline = try MobileSourceLibrary.validate(Data(replaced.utf8))
        let library = MobileSourceLibrary(directory: root.appendingPathComponent("custom"), bundled: { [baseline] })
        let search = baseline.search!
        func item(_ selector: String, url: String? = nil, format: String = "a") -> [String: Any] {
            ["factoryId": "web-selector", "version": 2, "arguments": ["name": "Custom source", "searchConfig": [
                "searchUrl": url ?? search.url.replacingOccurrences(of: "{query}", with: "{keyword}"),
                "subjectFormatId": format, "selectorSubjectFormatA": ["selectLists": selector],
                "selectorSubjectFormatIndexed": ["selectNames": "a", "selectLinks": "a"],
                "channelFormatId": "no-channel", "selectorChannelFormatNoChannel": ["selectEpisodes": "a.episode"]]]]
        }
        let currentItem = item("a.current")
        let oldItem = item("a.old")
        let both = try JSONSerialization.data(withJSONObject: ["mediaSources": [currentItem],
            "exportedMediaSourceDataList": ["mediaSources": [oldItem]]])
        let mirror = "https://arbitrary.example/rules.json?token=opaque"
        for body in [both, try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [currentItem]]])] {
            let importer = MobileSourceURLImport(probe: { _ in true }) { _ in body }
            importer.load(mirror, library: library)
            await idle(importer)
            precondition(importer.draft == nil && importer.subscriptionPreview == nil && importer.failure == nil)
            precondition(importer.batch?.drafts.count == 1)
            precondition(importer.batch?.drafts.first?.configuration.webSelector?.searchNames == "a.current")
            precondition(library.sources.first?.configuration.configurationRevision == baseline.configurationRevision)
            importer.clearPreview()
            precondition(importer.batch == nil)
        }
        let noSources = MobileSourceURLImport(probe: { _ in true }) { _ in both }
        noSources.load(mirror)
        await idle(noSources)
        precondition(noSources.failure == nil && noSources.batch?.drafts.count == 1)

        let unhealthy = MobileSourceURLImport(probe: { _ in false }) { _ in both }
        unhealthy.load(mirror, library: library)
        await idle(unhealthy)
        precondition(unhealthy.failure == nil && unhealthy.batch?.drafts.isEmpty == true)
        precondition(unhealthy.batch?.notices.count == 1)
        precondition(library.sources.first?.configuration.configurationRevision == baseline.configurationRevision)
        var goodItem = currentItem
        goodItem["id"] = "healthy-source"
        var args = goodItem["arguments"] as! [String: Any]
        args["name"] = "Healthy source"
        goodItem["arguments"] = args
        let mixedData = try JSONSerialization.data(withJSONObject: ["mediaSources": [currentItem, goodItem]])
        let mixedBatch = try MobileCSS1Configuration.convert(data: mixedData)
        let checked = try await MobileSourceURLImport.verified(mixedBatch) { config in
            if config.id == "healthy-source" { return true }
            throw PlaybackFailure.authenticationRequired
        }
        precondition(checked.drafts.map(\.configuration.id) == ["healthy-source"])
        precondition(checked.notices.count == 1 && checked.notices[0].contains("Custom source"))
        let nativeDraft = MobileSourceDraft(configuration: baseline, data: try baseline.encodedData())
        let nativeChecked = try await MobileSourceURLImport.verified(.init(drafts: [nativeDraft])) { _ in
            preconditionFailure("Native configuration should not be sampled")
        }
        precondition(nativeChecked.drafts.count == 1 && nativeChecked.notices.isEmpty)

        let checkGate = ConfigurationDownloadGate(Data())
        let checking = MobileSourceURLImport(probe: { _ in _ = await checkGate.fetch(); return true }) { _ in both }
        checking.load(mirror)
        while !(await checkGate.waiting) { await Task.yield() }
        checking.cancel()
        await checkGate.release()
        for _ in 0..<100 { await Task.yield() }
        precondition(checking.batch == nil && !checking.busy && checking.failure == nil)

        var duplicate = try JSONSerialization.jsonObject(with: baseline.encodedData()) as! [String: Any]
        duplicate["id"] = "same-host-source"
        let sameHost = try MobileSourceLibrary.validate(JSONSerialization.data(withJSONObject: duplicate))
        let ambiguous = try MobileSubscriptionConverter.convert(both, baselines: [baseline, sameHost], current: [baseline, sameHost])
        precondition(ambiguous.state.overrides.isEmpty)
        for invalid in [item("a", url: "https://www.custom.example/another?wd={keyword}"),
                        item("a", url: search.url.replacingOccurrences(of: "{query}", with: "{keyword}") + "&injected=value"),
                        item("a", format: "indexed")] {
            let body = try JSONSerialization.data(withJSONObject: ["mediaSources": [invalid]])
            let rejected = try MobileSubscriptionConverter.convert(body, baselines: [baseline], current: [baseline])
            precondition(rejected.state.overrides.isEmpty)
        }

        let gate = ConfigurationDownloadGate(both)
        let cancelled = MobileSourceURLImport(probe: { _ in true }) { _ in await gate.fetch() }
        cancelled.load(mirror, library: library)
        while !(await gate.waiting) { await Task.yield() }
        cancelled.cancel()
        await gate.release()
        for _ in 0..<100 { await Task.yield() }
        precondition(cancelled.batch == nil && cancelled.subscriptionPreview == nil && cancelled.failure == nil)
        print("PASS: standalone arbitrary-URL CSS1, top-level precedence/legacy fallback, legacy custom-host restrictions and cancellation")
    }

    private static func idle(_ importer: MobileSourceURLImport) async {
        while importer.busy { await Task.yield() }
    }
}
