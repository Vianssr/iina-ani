import SourceCore
import SourceRuntime
import Foundation
import Observation

struct MobileSearchOverride: Codable, Sendable {
    let baselineRevision: String
    let search: SourceConfiguration.Search
}
struct MobileSubscriptionState: Codable, Sendable {
    let fingerprint: String
    let checkedAt: Date
    let overrides: [String: MobileSearchOverride]
    let configurations: [String: Data]

    init(fingerprint: String, checkedAt: Date, overrides: [String: MobileSearchOverride], configurations: [String: Data] = [:]) {
        self.fingerprint = fingerprint; self.checkedAt = checkedAt; self.overrides = overrides
        self.configurations = configurations
    }
    private enum CodingKeys: String, CodingKey { case fingerprint, checkedAt, overrides, configurations }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        overrides = try c.decode([String: MobileSearchOverride].self, forKey: .overrides)
        configurations = try c.decodeIfPresent([String: Data].self, forKey: .configurations) ?? [:]
    }
}
struct MobileSubscriptionEntry: Identifiable, Sendable {
    let id: Int
    let sourceID: String?
    let name: String
    let status: String
    let detail: String
}
struct MobileSubscriptionPreview: Identifiable, Sendable {
    let id = UUID()
    let state: MobileSubscriptionState
    let revisions: [String: String]
    let entries: [MobileSubscriptionEntry]
}
enum MobileSubscriptionError: Error { case malformed, stale, unavailable }

/// Only mobile preview lifetime and persistence live here. Conversion, policy and checks are shared with desktop.
@MainActor @Observable
final class MobileSourceSubscription {
    private(set) var preview: MobileSubscriptionPreview?
    private(set) var busy = false
    private(set) var failed = false
    private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    deinit { task?.cancel() }
    func cancel() { generation += 1; task?.cancel(); task = nil; preview = nil; busy = false; failed = false }

    static func download() async throws -> Data {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-source-import-ui-fixture") {
            let baselines = try SourceSubscriptionBaselines.load()
            guard let source = baselines["fqdm"] else { throw MobileSubscriptionError.unavailable }
            let item: [String: Any] = ["id": "fixture-search-rules", "factoryId": "web-selector", "version": 2,
                "arguments": ["name": "Tomato search rules", "searchConfig": [
                    "searchUrl": source.search.url.replacingOccurrences(of: "{query}", with: "{keyword}"),
                    "subjectFormatId": "a", "selectorSubjectFormatA": ["selectLists": "a.fixture-search-result"]]]]
            return try JSONSerialization.data(withJSONObject: ["mediaSources": [item]])
        }
        #endif
        return try await SourceSubscriptionTransport.download()
    }

    static var fixtureSearchFetch: SourceHTTPTransport.Fetch? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-source-import-ui-fixture") {
            return { request in
                guard let url = request.url else { throw MobileSubscriptionError.unavailable }
                return SourceHTTPResponse(data: Data("<a class='fixture-search-result' href='/index.php/vod/detail/id/42.html'>Source Flow Fixture</a>".utf8), url: url, statusCode: 200)
            }
        }
        #endif
        return nil
    }

    func check(library: MobileSourceLibrary,
               fetch: @escaping @Sendable () async throws -> Data = { try await MobileSourceSubscription.download() },
               searchFetch: SourceHTTPTransport.Fetch? = nil) {
        cancel(); failed = false; busy = true
        let expected = generation
        library.reload()
        let baselines = library.subscriptionBaselines
        let current = library.sources
        task = Task { [weak self] in
            do {
                let prepared = try await Self.prepare(baselines: baselines, current: current, fetch: fetch,
                    searchFetch: searchFetch ?? Self.fixtureSearchFetch)
                guard let self, self.generation == expected else { return }
                try library.validateSubscriptionRevisions(prepared.revisions)
                self.preview = prepared
                self.busy = false; self.task = nil
            } catch {
                guard let self, self.generation == expected, !Task.isCancelled else { return }
                self.failed = true; self.busy = false; self.task = nil
            }
        }
    }

    static func prepare(baselines: [String: NativeSearchSource], current: [MobileSourceEntry],
                        fetch: @Sendable () async throws -> Data,
                        searchFetch: SourceHTTPTransport.Fetch? = nil) async throws -> MobileSubscriptionPreview {
        let data = try await fetch()
        try Task.checkCancellation()
        let installed = Dictionary(uniqueKeysWithValues: current.compactMap { entry in entry.search.map { (entry.id, $0) } })
        let names = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.source.name) })
        let converted = try SourceSubscriptionConverter.convert(data: data, baselines: baselines, installed: installed, names: names)
        let sources = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.source) })
        let verified = try await SourceSubscriptionVerifier.verifyChangedSearches(converted,
            baselines: baselines, installed: installed, item: { id, raw in try? sources[id]?.item(raw) }, fetch: searchFetch)
        try Task.checkCancellation()
        var overrides: [String: MobileSearchOverride] = [:]
        for (id, data) in verified.overrides {
            guard let baseline = baselines[id] else { throw MobileSubscriptionError.stale }
            let changed = try JSONDecoder().decode(NativeSearchSource.self, from: data)
            overrides[id] = MobileSearchOverride(baselineRevision: try SourceSubscriptionBaselines.revision(of: baseline), search: changed.search)
        }
        let entries = verified.entries.enumerated().map { index, value in
            MobileSubscriptionEntry(id: index, sourceID: value.sourceID, name: value.name,
                status: value.status, detail: value.detail)
        }
        return MobileSubscriptionPreview(state: MobileSubscriptionState(fingerprint: verified.fingerprint,
            checkedAt: verified.checkedAt, overrides: overrides, configurations: verified.configurations), revisions: Dictionary(uniqueKeysWithValues: current.map {
                ($0.id, $0.source.configurationRevision + ":" + $0.searchRevision)
            }), entries: entries)
    }


    func apply(_ value: MobileSubscriptionPreview, library: MobileSourceLibrary) throws {
        guard preview?.id == value.id else { throw MobileSubscriptionError.stale }
        try library.applySubscription(value)
        preview = nil
    }
}
