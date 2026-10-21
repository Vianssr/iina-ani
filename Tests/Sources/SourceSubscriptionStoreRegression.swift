import Foundation
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
        print("PASS subscription persistence, identity, omission, stale preview, upstream isolation, corrupt reload, failed-write atomicity and default subscription-only search")
    }
}
