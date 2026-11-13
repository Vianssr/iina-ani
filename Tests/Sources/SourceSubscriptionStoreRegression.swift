import Foundation
import SourceCore
import enum SourceRuntime.SourceWebConfigurationConverter
import struct SourceRuntime.SourceSubscriptionPlan
import enum SourceRuntime.SourceSubscriptionConverter
import enum SourceRuntime.SourceSubscriptionFailure
@testable import IINA_ANI

@main enum SourceSubscriptionStoreRegression {
    enum Failure: Error { case assertion(String) }
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.assertion(message) }
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let builtins = root.appendingPathComponent("IINA-ANI/Sources")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let users = temporary.appendingPathComponent("sources")
        let registry = SourceRegistry(builtinDirectory: builtins, userDirectory: users)
        for id in SourceSubscriptionConverter.managedSourceIDs {
            try require(registry.descriptor(for: id)?.capabilities.contains(.search) == false, "default registry leaked legacy search capability")
            try require(registry.nativeSearch(for: id) == nil && registry.builtinSearch(for: id) != nil, "legacy search must remain conversion-only")
            try require(registry.descriptor(for: id)?.capabilities.contains(.resolve) == true, "subscription gate removed direct URL resolution")
        }
        try require(registry.nativeSearch(for: "bilibili") != nil, "original project search must remain available")
        let original = registry.builtinSearch(for: "fqdm")!
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        var search = object["search"] as! [String: Any]
        search["resultsSelector"] = "a.subscription-result"
        object["search"] = search
        let override = try JSONSerialization.data(withJSONObject: object)
        let plan = SourceSubscriptionPlan(fingerprint: "revision-one", checkedAt: Date(), overrides: ["fqdm": override], entries: [])
        let revision = registry.revision
        let item = try registry.item(for: "https://www.fqdm.cc/index.php/vod/detail/id/7.html")
        try registry.applySubscription(plan, expectedRevision: revision)
        try require(registry.subscriptionSearch(for: "fqdm")?.search.resultsSelector == "a.subscription-result", "accepted update must affect configured-source search")
        try require(try registry.item(for: item.pageURL) == item, "search update must retain source/work identity")
        let restarted = SourceRegistry(builtinDirectory: builtins, userDirectory: users)
        try require(restarted.subscriptionSearch(for: "fqdm")?.search.resultsSelector == "a.subscription-result", "restart must recover sanitized snapshot")
        do {
            try registry.applySubscription(plan, expectedRevision: revision)
            throw Failure.assertion("stale preview accepted")
        } catch SourceSubscriptionFailure.stalePreview { }
        let missing = SourceSubscriptionPlan(fingerprint: "revision-two", checkedAt: Date(), overrides: [:], entries: [])
        try registry.applySubscription(missing, expectedRevision: registry.revision)
        try require(registry.subscriptionSearch(for: "fqdm")?.search.resultsSelector == "a.subscription-result", "missing entries must not delete last usable configuration")
        let file = users.appendingPathComponent("subscriptions/css1.json")
        let saved = try Data(contentsOf: file)
        let bad = SourceSubscriptionPlan(fingerprint: "bad", checkedAt: Date(), overrides: ["bilibili": override], entries: [])
        do {
            try registry.applySubscription(bad, expectedRevision: registry.revision)
            throw Failure.assertion("original upstream site overwritten")
        } catch SourceSearchError.invalidConfiguration { }
        try require(try Data(contentsOf: file) == saved, "invalid update must not overwrite disk")
        try Data("broken".utf8).write(to: file)
        do {
            try registry.reload(builtinDirectory: builtins, userDirectory: users)
            throw Failure.assertion("corrupt persisted snapshot accepted")
        } catch is DecodingError { }
        try require(registry.subscriptionSearch(for: "fqdm")?.search.resultsSelector == "a.subscription-result", "failed reload must retain active configuration")
        try saved.write(to: file, options: .atomic)
        let beforeFailure = registry.revision
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            try registry.applySubscription(plan, expectedRevision: beforeFailure)
            throw Failure.assertion("failed disk write published")
        } catch is CocoaError { }
        try require(registry.revision == beforeFailure, "write failure must not publish a generation")
        try require(registry.snapshot.subscription?.fingerprint == "revision-two", "write failure must preserve prior version")
        let isolatedUsers = temporary.appendingPathComponent("isolated-sources")
        let isolated = SourceRegistry(builtinDirectory: builtins, userDirectory: isolatedUsers)
        for id in SourceSubscriptionConverter.managedSourceIDs {
            try require(isolated.descriptor(for: id)?.capabilities.contains(.search) == false, "unsubscribed registry leaked searchable source")
            try require(isolated.nativeSearch(for: id) == nil && isolated.builtinSearch(for: id) != nil, "baseline must be conversion-only")
        }
        try require(isolated.descriptor(for: "bilibili")?.capabilities.contains(.search) == true, "upstream search must remain available")
        let decoder = VideoDecoder(registry: isolated)
        do {
            _ = try await decoder.searchSource(sourceID: "fqdm", query: "test", page: 1, classifyWithBangumi: false)
            throw Failure.assertion("configured baseline bypassed subscription gate")
        } catch VideoGetError.notSupported { }
        try isolated.applySubscription(plan, expectedRevision: isolated.revision)
        try require(isolated.descriptor(for: "fqdm")?.capabilities.contains(.search) == true, "applied configured source not activated")
        try require(isolated.descriptor(for: "xifan")?.capabilities.contains(.search) == false, "unapplied source activated implicitly")
        let isolatedRestart = SourceRegistry(builtinDirectory: builtins, userDirectory: isolatedUsers)
        try require(isolatedRestart.descriptor(for: "fqdm")?.capabilities.contains(.search) == true && isolatedRestart.nativeSearch(for: "xifan") == nil, "restart lost activation boundary")
        let native = isolated.builtinSearch(for: "xifan")!
        let nativePlan = SourceSubscriptionPlan(fingerprint: "native", checkedAt: Date(),
            overrides: ["xifan": try JSONEncoder().encode(native)], entries: [])
        try isolated.applySubscription(nativePlan, expectedRevision: isolated.revision)
        try require(isolated.nativeSearch(for: "xifan") != nil && isolated.descriptor(for: "xifan")?.capabilities.contains(.search) == true, "native adapter search not activated by subscription")
        try require(isolated.nativeSearch(for: "fqdm")?.search.resultsSelector == "a.subscription-result", "native activation dropped configured subscription")
        try await staticSubscription(root: root, directory: temporary.appendingPathComponent("static-sources"))
        print("PASS subscription persistence, identity, omission, stale preview, upstream isolation, corrupt reload, failed-write atomicity and default subscription-only search")
    }
    @MainActor static func staticSubscription(root: URL, directory: URL) async throws {
        let item: [String: Any] = ["factoryId": "web-selector", "version": 2, "arguments": [
            "name": "Static subscription", "searchConfig": ["searchUrl": "https://static-store.example/search?q={keyword}",
                "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": "a.result"],
                "channelFormatId": "no-channel", "selectorChannelFormatNoChannel": ["selectEpisodes": "a.episode"]]]]
        let feed = try JSONSerialization.data(withJSONObject: ["exportedMediaSourceDataList": ["mediaSources": [item]]])
        let configuration = try SourceWebConfigurationConverter.configuration(item)
        let registry = SourceRegistry(builtinDirectory: root.appendingPathComponent("IINA-ANI/Sources"), userDirectory: directory)
        let endpoint = URL(string: "https://mirror.example/online.json")!
        let service = SourceSubscriptionService(registry: registry, fetchURL: { url in
            try require(url == endpoint, "custom subscription URL was ignored")
            return feed
        })
        let cancelled = try await service.check(url: endpoint)
        try require(cancelled.configurations.count == 1 && cancelled.overrides.isEmpty && registry.source(for: configuration.id) == nil,
                    "static sources must be previewed without installing")
        service.cancelPendingCheck()
        do { try service.apply(cancelled); throw Failure.assertion("cancelled static preview applied") }
        catch SourceSubscriptionFailure.stalePreview {}
        let plan = try await service.check(url: endpoint)
        try service.apply(plan)
        try require(registry.source(for: configuration.id)?.version == 4 &&
                    registry.descriptor(for: configuration.id)?.capabilities.contains(.search) == true,
                    "static configuration missing after atomic apply")
        let work = try registry.item(for: "https://static-store.example/show/one")
        let episode = try registry.item(for: "https://static-store.example/watch/second", expectedKind: .episode)
        try require(work.kind == .work && episode.kind == .episode && work.sourceID == configuration.id && episode.sourceID == configuration.id,
                    "desktop static page identity must use the caller's catalog role")
        let nodes = [VideoTreeNode(title: "A", children: [
            VideoTreeNode(site: .configured(configuration.id), index: 1, title: "Episode 1", id: "first", url: "https://static-store.example/watch/first"),
            VideoTreeNode(site: .configured(configuration.id), index: 2, title: "Episode 2", id: "second", url: episode.pageURL)])]
        let first = try registry.item(for: nodes[0].children[0].selectionURL, expectedKind: .episode)
        let next = AutoplaySelection.next(after: PlayableSelection(item: work, episode: first, qualityID: "Line 1"), in: nodes, registry: registry)
        try require(next?.item == work && next?.episode == episode && next?.qualityID == "Line 1", "static autoplay lost exact work or line")
        try require(try registry.episodeIdentity(for: nodes[0].children[1]) == "\(configuration.id):episode:\(episode.pageURL)", "static update identity used catalog index")
        let restarted = SourceRegistry(builtinDirectory: root.appendingPathComponent("IINA-ANI/Sources"), userDirectory: directory)
        try require(restarted.source(for: configuration.id)?.configurationRevision == configuration.configurationRevision, "static sources did not survive restart")
        let empty = SourceSubscriptionPlan(fingerprint: "empty", checkedAt: Date(), overrides: [:], entries: [])
        try restarted.applySubscription(empty, expectedRevision: restarted.revision)
        try require(restarted.source(for: configuration.id) != nil, "omitted static source deleted")
        let file = directory.appendingPathComponent("subscriptions/css1.json")
        let preserved = try Data(contentsOf: file)
        var bad = try JSONSerialization.jsonObject(with: configuration.encodedData()) as! [String: Any]
        bad["id"] = "web-conflicting"
        let conflicting = try JSONSerialization.data(withJSONObject: bad)
        let conflict = SourceSubscriptionPlan(fingerprint: "conflict", checkedAt: Date(), overrides: [:], entries: [], configurations: ["web-conflicting": conflicting])
        do { try restarted.applySubscription(conflict, expectedRevision: restarted.revision); throw Failure.assertion("conflicting static host accepted") }
        catch SourceRegistry.RegistryError.hostConflict {}
        try require(try Data(contentsOf: file) == preserved, "static host conflict changed persisted data")
        print("PASS static subscription custom URL preview, cancellation, atomic apply/restart, typed leaf identity and conflict isolation")
    }

}
