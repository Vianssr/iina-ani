import Foundation

private actor DanmakuGate {
    private var request: CheckedContinuation<[MobileDanmakuEntry], Error>?
    private var started = false
    private var observers: [CheckedContinuation<Void, Never>] = []

    func load(_ target: MobileDanmakuTarget) async throws -> [MobileDanmakuEntry] {
        started = true
        observers.forEach { $0.resume() }
        observers.removeAll()
        // Deliberately ignore cancellation here: stale replies must still be rejected.
        return try await withCheckedThrowingContinuation { request = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func finish(_ entries: [MobileDanmakuEntry]) { request?.resume(returning: entries); request = nil }
    func fail(_ error: Error) { request?.resume(throwing: error); request = nil }
}

private actor ProviderFixture {
    var calls = 0
    let metadata: Data
    let xml: Data
    init(metadata: String, xml: String) { self.metadata = Data(metadata.utf8); self.xml = Data(xml.utf8) }
    func fetch(_ url: URL) -> Data { calls += 1; return url.host == "api.bilibili.com" ? metadata : xml }
    func count() -> Int { calls }
}

@main
struct MobileAutomaticDanmakuRegression {
    @MainActor static func main() async throws {
        let target = makeTarget(cid: 9)
        let xml = "<i><chatid>9</chatid><d p=\"1,1,25,16777215\">verified</d></i>"
        let metadata = #"{"code":0,"data":{"aid":7,"pages":[{"cid":9}]}}"#
        let fixture = ProviderFixture(metadata: metadata, xml: xml)
        let provider = MobileBilibiliDanmakuProvider(fetch: { await fixture.fetch($0) })
        let result = try await provider.comments(for: target)
        precondition(result.count == 1 && result[0].text == "verified" && result[0].time == 1)
        let calls = await fixture.count()
        precondition(calls == 2)
        let empty = try MobileDanmakuParser.parseBilibili(data: Data("<i><chatid>9</chatid></i>".utf8), expectedCID: 9)
        precondition(empty.isEmpty, "A verified empty pool is not a parsing failure")
        for bad in [
            "<i><chatid>10</chatid></i>", "<i/>", "<i><chatid>9</chatid><chatid>9</chatid></i>",
            "<other><chatid>9</chatid></other>", "<i><chatid><x>9</x></chatid></i>",
            "<!DOCTYPE i [<!ENTITY x '9'>]><i><chatid>&x;</chatid></i>",
            "<i><chatid>9</chatid><d p=\"1,1,25,0\">unterminated"
        ] {
            precondition((try? MobileDanmakuParser.parseBilibili(data: Data(bad.utf8), expectedCID: 9)) == nil)
        }
        precondition((try? MobileDanmakuParser.parseBilibili(data: Data(repeating: 65, count: MobileDanmakuParser.maximumBytes + 1), expectedCID: 9)) == nil)
        for badMetadata in [
            #"{"code":0,"data":{"aid":8,"pages":[{"cid":9}]}}"#,
            #"{"code":0,"data":{"aid":7,"pages":[{"cid":10}]}}"#,
            #"{"code":0,"data":{"aid":7,"pages":[{"cid":9},{"cid":9}]}}"#,
            #"{"code":0,"data":{"aid":true,"pages":[{"cid":9}]}}"#,
            #"{"code":0,"data":{"aid":7,"pages":[{"cid":9.5}]}}"#
        ] {
            let bad = ProviderFixture(metadata: badMetadata, xml: xml)
            do {
                _ = try await MobileBilibiliDanmakuProvider(fetch: { await bad.fetch($0) }).comments(for: target)
                preconditionFailure("Unverified provider identity accepted")
            } catch {}
            let calls = await bad.count()
            precondition(calls == 1, "Do not download comments for an unverified episode")
        }
        do {
            try MobileBilibiliDanmakuProvider.verify(metadata: Data(#"{"code":-101,"data":null}"#.utf8), target: target)
            preconditionFailure("Login-required metadata accepted")
        } catch { precondition(error as? MobileAutomaticDanmakuFailure == .authenticationRequired) }

        let suite = "AutomaticDanmakuRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = DanmakuGate()
        let store = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await gate.load($0) })
        store.beginEpisode(target: nil, authority: {})
        precondition(store.automaticStatus == .unsupported && store.entries.isEmpty)
        store.beginEpisode(target: target, authority: {})
        await gate.waitUntilStarted()
        precondition(store.automaticStatus == .loading)
        await gate.finish(result)
        await settle(store)
        precondition(store.automaticStatus == .loaded && store.entries == result)
        precondition(store.activeEntries(at: 1).count == 1 && store.activeEntries(at: 20).isEmpty,
                     "Attachment timestamps follow the actual playback position, not download time")
        store.automaticEnabled = false
        precondition(store.automaticStatus == .off && store.entries.isEmpty)
        precondition(!MobileDanmakuStore(defaults: defaults).automaticEnabled)

        let manualGate = DanmakuGate()
        let manual = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await manualGate.load($0) })
        manual.automaticEnabled = true
        manual.beginEpisode(target: target, authority: {})
        await manualGate.waitUntilStarted()
        try manual.parse(data: Data(#"[{"time":2,"text":"manual"}]"#.utf8))
        await manualGate.finish(result)
        await drain()
        precondition(manual.automaticStatus == .manual && manual.entries.first?.text == "manual")
        manual.retryAutomatic()
        manual.automaticEnabled = false
        manual.automaticEnabled = true
        precondition(manual.entries.first?.text == "manual", "Retry and toggles cannot replace a successful manual import")

        let oldGate = DanmakuGate()
        let newGate = DanmakuGate()
        let switching = MobileDanmakuStore(defaults: defaults, automaticLoader: { target in
            if target.cid == 9 { return try await oldGate.load(target) }
            return try await newGate.load(target)
        })
        switching.beginEpisode(target: target, authority: {})
        await oldGate.waitUntilStarted()
        switching.beginEpisode(target: makeTarget(cid: 10), authority: {})
        precondition(switching.entries.isEmpty, "Clear previous episode before awaiting the next fetch")
        await newGate.waitUntilStarted()
        await oldGate.finish(result)
        await drain()
        precondition(switching.automaticStatus == .loading && switching.entries.isEmpty)
        await newGate.finish([])
        await settle(switching)
        precondition(switching.automaticStatus == .empty)

        let staleGate = DanmakuGate()
        let stale = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await staleGate.load($0) })
        var authorized = true
        stale.beginEpisode(target: target) {
            if !authorized { throw MobileAutomaticDanmakuFailure.configurationChanged }
        }
        await staleGate.waitUntilStarted()
        authorized = false
        await staleGate.finish(result)
        await settle(stale)
        precondition(stale.entries.isEmpty && stale.automaticStatus == .failed(.configurationChanged))

        let cancelGate = DanmakuGate()
        let cancelled = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await cancelGate.load($0) })
        cancelled.beginEpisode(target: target, authority: {})
        await cancelGate.waitUntilStarted()
        cancelled.cancelAutomatic()
        await cancelGate.finish(result)
        await drain()
        precondition(cancelled.entries.isEmpty && cancelled.automaticStatus == .cancelled)
        cancelled.clear()
        precondition(cancelled.automaticStatus == .idle)

        let offGate = DanmakuGate()
        let off = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await offGate.load($0) })
        off.beginEpisode(target: target, authority: {})
        await offGate.waitUntilStarted()
        off.automaticEnabled = false
        await offGate.finish(result)
        await drain()
        precondition(off.entries.isEmpty && off.automaticStatus == .off, "A delayed download cannot undo automatic off")
        off.automaticEnabled = true
        off.clear()

        let stoppedGate = DanmakuGate()
        let stopped = MobileDanmakuStore(defaults: defaults, automaticLoader: { try await stoppedGate.load($0) })
        stopped.beginEpisode(target: target, authority: {})
        await stoppedGate.waitUntilStarted()
        stopped.clear()
        await stoppedGate.finish(result)
        await drain()
        precondition(stopped.entries.isEmpty && stopped.automaticStatus == .idle, "Session teardown rejects a late result")

        var attempt = 0
        let retry = MobileDanmakuStore(defaults: defaults, automaticLoader: { _ in throw MobileAutomaticDanmakuFailure.network })
        retry.beginEpisode(target: target) { attempt += 1 }
        await settle(retry)
        precondition(retry.automaticStatus == .failed(.network) && retry.entries.isEmpty && attempt == 1)
        retry.retryAutomatic()
        await settle(retry)
        precondition(attempt == 2, "Errors retry only on explicit request")
        print("PASS: exact public provider identities, XML boundaries, empty pool, automatic off/status/retry, switching, cancellation, configuration revocation and manual precedence")
    }

    private static func makeTarget(cid: Int64) -> MobileDanmakuTarget {
        MobileDanmakuTarget(episodeID: UUID(), sourceID: "source", pageURL: "https://example.org/episode/\(cid)",
                            configurationRevision: "revision-1", aid: 7, cid: cid)
    }

    @MainActor private static func settle(_ store: MobileDanmakuStore) async {
        for _ in 0..<2_000 {
            if store.automaticStatus != .loading { return }
            await Task.yield()
        }
        preconditionFailure("Automatic request did not settle")
    }

    private static func drain() async { for _ in 0..<100 { await Task.yield() } }
}
