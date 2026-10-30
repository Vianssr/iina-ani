import Foundation
import CryptoKit
import SwiftSoup
import Observation

struct MobileSearchOverride: Codable, Sendable {
    let baselineRevision: String
    let search: SourceConfiguration.Search
}
struct MobileSubscriptionState: Codable, Sendable {
    let fingerprint: String
    let checkedAt: Date
    let overrides: [String: MobileSearchOverride]
}
struct MobileSubscriptionEntry: Identifiable, Sendable {
    let id: Int
    let sourceID: String?
    let name: String
    let status: String
    let before: String?
    let after: String?
}
struct MobileSubscriptionPreview: Identifiable, Sendable {
    let id = UUID()
    let state: MobileSubscriptionState
    let revisions: [String: String]
    let entries: [MobileSubscriptionEntry]
}
enum MobileSubscriptionError: Error { case malformed, stale, unavailable }

/// css1 v2 is search metadata, not a complete configuration or a remotely executable parser.
/// Host identity, fixed path/query fields and supported CSS formats follow the desktop converter.
enum MobileSubscriptionConverter {
    /// New exports carry current entries at the root; older exports wrap the same array.
    static func mediaSources(in root: [String: Any]) throws -> [Any] {
        let value: Any?
        if let current = root["mediaSources"] { value = current }
        else { value = (root["exportedMediaSourceDataList"] as? [String: Any])?["mediaSources"] }
        guard let items = value as? [Any], items.count <= 128,
              items.isEmpty || items.contains(where: { (($0 as? [String: Any])?["arguments"] as? [String: Any])?["searchConfig"] is [String: Any] }) else {
            throw MobileSubscriptionError.malformed
        }
        return items
    }

    static func replacingSearch(_ search: SourceConfiguration.Search, in config: SourceConfiguration) throws -> SourceConfiguration {
        var object = try JSONSerialization.jsonObject(with: config.encodedData()) as! [String: Any]
        object["search"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(search))
        return try SourceConfiguration.load(data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }
    static func convert(_ data: Data, baselines: [SourceConfiguration], current: [SourceConfiguration]) throws -> MobileSubscriptionPreview {
        guard !data.isEmpty, data.count <= 2 * 1024 * 1024,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MobileSubscriptionError.malformed
        }
        let items = try mediaSources(in: root)
        var overrides: [String: MobileSearchOverride] = [:]
        var signatures: [String: Data] = [:]
        var rejected = Set<String>()
        var entries: [MobileSubscriptionEntry] = []
        for (index, raw) in items.enumerated() {
            let item = raw as? [String: Any]
            let args = item?["arguments"] as? [String: Any]
            let config = args?["searchConfig"] as? [String: Any]
            let name = String(String((args?["name"] as? String ?? "css1").prefix(160)).unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined())
            let host = (config?["searchUrl"] as? String).flatMap { URLComponents(string: $0)?.host?.lowercased() }
            let candidates = host.map { value in baselines.filter { $0.hosts.contains { $0.lowercased() == value } } } ?? []
            // Multiple installed configurations claiming one host are ambiguous, even for known sites.
            let baseline = candidates.count == 1 ? candidates.first : nil
            let id = baseline?.id
            guard let id, let baseline, let local = baseline.search, local.format == "html",
                  baseline.effectiveCapabilities(on: .iOS).isSuperset(of: [.search, .episodes, .resolve, .mpv]) else {
                entries.append(.init(id: index, sourceID: id, name: name, status: "Unsupported source; kept unchanged", before: nil, after: nil)); continue
            }
            do {
                guard item?["factoryId"] as? String == "web-selector", let version = item?["version"] as? Int,
                      version == 2, !(item?["version"] is Bool), let config,
                      let rawURL = config["searchUrl"] as? String else { throw MobileSubscriptionError.malformed }
                let url = try safeURL(rawURL, baseline: baseline, local: local)
                var search = try JSONSerialization.jsonObject(with: JSONEncoder().encode(local)) as! [String: Any]
                var signature = ["url": url, "format": config["subjectFormatId"] as? String ?? ""]
                switch config["subjectFormatId"] as? String {
                case "a":
                    guard let selector = (config["selectorSubjectFormatA"] as? [String: Any])?["selectLists"] as? String else { throw MobileSubscriptionError.malformed }
                    try validateSelector(selector)
                    signature["selector"] = normalized(selector)
                    if id != "fengche" && id != "haixing" {
                        search["resultsSelector"] = selector; search["titleSelector"] = "self"; search["hrefAttribute"] = "href"
                        search.removeValue(forKey: "linkSelector"); search.removeValue(forKey: "coverSelector"); search.removeValue(forKey: "coverAttribute")
                    }
                case "indexed":
                    guard let expected = SourceSubscriptionRules.indexedSelectors[id], let fields = config["selectorSubjectFormatIndexed"] as? [String: Any],
                          let names = fields["selectNames"] as? String, let links = fields["selectLinks"] as? String,
                          normalized(names) == normalized(expected.0), normalized(links) == normalized(expected.1) else { throw MobileSubscriptionError.malformed }
                    try validateSelector(names); try validateSelector(links)
                    signature["names"] = normalized(names); signature["links"] = normalized(links)
                default: throw MobileSubscriptionError.malformed
                }
                search["url"] = url
                let converted = try JSONDecoder().decode(SourceConfiguration.Search.self, from: JSONSerialization.data(withJSONObject: search))
                _ = try replacingSearch(converted, in: baseline)
                let bytes = try JSONSerialization.data(withJSONObject: signature, options: [.sortedKeys])
                if let previous = signatures[id], previous != bytes { rejected.insert(id) }
                signatures[id] = bytes
                overrides[id] = .init(baselineRevision: baseline.configurationRevision, search: converted)
                entries.append(.init(id: index, sourceID: id, name: name, status: "Search rules ready to apply", before: current.first(where: { $0.id == id })?.search.map(summary), after: summary(converted)))
            } catch {
                rejected.insert(id)
                entries.append(.init(id: index, sourceID: id, name: name, status: "Unsupported rules; kept unchanged", before: nil, after: nil))
            }
        }
        for id in rejected { overrides.removeValue(forKey: id) }
        entries = entries.map { entry in
            guard let id = entry.sourceID, rejected.contains(id) else { return entry }
            return .init(id: entry.id, sourceID: id, name: entry.name, status: "Conflicting or unsupported rules; kept unchanged", before: entry.before, after: nil)
        }
        return .init(state: .init(fingerprint: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), checkedAt: .now, overrides: overrides),
                     revisions: Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.configurationRevision) }), entries: entries)
    }
    private static func safeURL(_ raw: String, baseline: SourceConfiguration, local: SourceConfiguration.Search) throws -> String {
        guard raw.utf8.count <= 4096, raw.contains("{keyword}"), !raw.contains(where: { $0.isWhitespace }),
              let incoming = URLComponents(string: raw), incoming.scheme == "https", incoming.user == nil,
              incoming.password == nil, incoming.port == nil, incoming.fragment == nil, let host = incoming.host?.lowercased(),
              baseline.hosts.contains(where: { $0.lowercased() == host }),
              let approved = URLComponents(string: local.url), incoming.path == approved.path, !incoming.path.contains("..") else { throw MobileSubscriptionError.malformed }
        var keys = Set<String>(); var hasQuery = false
        for field in incoming.queryItems ?? [] {
            guard keys.insert(field.name).inserted else { throw MobileSubscriptionError.malformed }
            if field.name == local.queryParameter {
                guard field.value == "{keyword}" else { throw MobileSubscriptionError.malformed }; hasQuery = true
            } else if field.name == local.pageParameter {
                guard field.value == "{page}" else { throw MobileSubscriptionError.malformed }
            } else {
                guard let fixed = approved.queryItems?.first(where: { $0.name == field.name }), fixed.value == field.value,
                      !(field.value?.contains("{") ?? false) else { throw MobileSubscriptionError.malformed }
            }
        }
        guard hasQuery else { throw MobileSubscriptionError.malformed }
        let result = raw.replacingOccurrences(of: "{keyword}", with: "{query}")
        let sample = result.replacingOccurrences(of: "{query}", with: "probe").replacingOccurrences(of: "{page}", with: "1")
        guard !sample.contains("{"), !sample.contains("}"), URL(string: sample) != nil else { throw MobileSubscriptionError.malformed }
        return result
    }
    private static func normalized(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").replacingOccurrences(of: " >", with: ">").replacingOccurrences(of: "> ", with: ">")
    }
    private static func validateSelector(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MobileSubscriptionError.malformed }
        _ = try SwiftSoup.parse("").select(value)
    }
    static func summary(_ search: SourceConfiguration.Search) -> String {
        [search.url, search.resultsSelector, search.titleSelector, search.linkSelector, search.coverSelector].compactMap { $0 }.joined(separator: "\n")
    }
}

@MainActor @Observable
final class MobileSourceSubscription {
    private(set) var preview: MobileSubscriptionPreview?
    private(set) var busy = false
    private(set) var failed = false
    private var generation = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    deinit { task?.cancel() }
    func cancel() { generation += 1; task?.cancel(); task = nil; preview = nil; busy = false; failed = false }
    func check(library: MobileSourceLibrary,
               fetch: @escaping @Sendable () async throws -> Data,
               probe: @escaping (SourceConfiguration) async throws -> Bool = { !(try await MobileSourceClient.make(configuration: $0).search("海贼王")).works.isEmpty }) {
        cancel(); failed = false; busy = true
        let expected = generation
        library.reload()
        let baselines = library.subscriptionBaselines
        let current = library.sources.map(\.configuration)
        task = Task { [weak self] in
            do {
                let prepared = try await Self.prepare(baselines: baselines, current: current, fetch: fetch, probe: probe)
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

    /// URL import and explicit review share the same conversion and verification.
    static func prepare(baselines: [SourceConfiguration], current: [SourceConfiguration],
                        fetch: @Sendable () async throws -> Data,
                        probe: (SourceConfiguration) async throws -> Bool) async throws -> MobileSubscriptionPreview {
        let data = try await fetch()
        try Task.checkCancellation()
        let converted = try MobileSubscriptionConverter.convert(data, baselines: baselines, current: current)
        var accepted = converted.state.overrides
        var rejected = Set<String>()
        for (id, change) in accepted.sorted(by: { $0.key < $1.key }) {
            guard let baseline = baselines.first(where: { $0.id == id }), let installed = current.first(where: { $0.id == id }) else { throw MobileSubscriptionError.stale }
            let replacement = try MobileSubscriptionConverter.replacingSearch(change.search, in: baseline)
            if replacement.configurationRevision != installed.configurationRevision {
                do { guard try await probe(replacement) else { throw MobileSubscriptionError.unavailable } }
                catch { try Task.checkCancellation(); accepted.removeValue(forKey: id); rejected.insert(id) }
            }
            try Task.checkCancellation()
        }
        let entries = converted.entries.map { entry -> MobileSubscriptionEntry in
            guard let id = entry.sourceID, rejected.contains(id) else { return entry }
            return .init(id: entry.id, sourceID: id, name: entry.name, status: "Search verification failed; kept unchanged", before: entry.before, after: nil)
        }
        return .init(state: .init(fingerprint: converted.state.fingerprint, checkedAt: converted.state.checkedAt, overrides: accepted), revisions: converted.revisions, entries: entries)
    }

    func apply(_ value: MobileSubscriptionPreview, library: MobileSourceLibrary) throws {
        guard preview?.id == value.id else { throw MobileSubscriptionError.stale }
        try library.applySubscription(value)
        preview = nil
    }

}
