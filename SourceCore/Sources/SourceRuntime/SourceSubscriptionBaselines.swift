import CryptoKit
import Foundation
import SourceCore

public enum SourceSubscriptionBaselineError: Error, LocalizedError, Equatable {
    case missingResource(String)
    case invalidResource

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return String(localized: "找不到本機來源搜尋基線：\(name)。")
        case .invalidResource: return String(localized: "本機來源搜尋基線格式無效。")
        }
    }
}

/// Audited desktop resources are conversion baselines, not an enabled subscription.
public enum SourceSubscriptionBaselines {
    private struct NativeSearchResources: Decodable {
        let version: Int
        let sources: [String: NativeSearchSource]
    }

    private static let cached: Result<[String: NativeSearchSource], Error> = Result { try loadResources() }

    public static func load() throws -> [String: NativeSearchSource] {
        try cached.get()
    }

    private static func loadResources() throws -> [String: NativeSearchSource] {
        let resources = try JSONDecoder().decode(NativeSearchResources.self, from: resource("native-search"))
        guard resources.version == 1 else { throw SourceSubscriptionBaselineError.invalidResource }
        // The desktop resource also contains Bilibili; it is outside this CSS1 runtime.
        var sources = resources.sources.filter { SourceSubscriptionRules.hosts[$0.key] != nil }
        let configured = try SourceConfiguration.load(data: resource("fqdm"))
        guard configured.id == "fqdm", configured.webSelector == nil, let search = configured.search else {
            throw SourceSubscriptionBaselineError.invalidResource
        }
        sources[configured.id] = NativeSearchSource(hosts: configured.hosts, search: search)
        guard Set(sources.keys) == SourceSubscriptionConverter.managedSourceIDs else {
            throw SourceSubscriptionBaselineError.invalidResource
        }
        return sources
    }

    /// Search-only compatibility revision. Never substitute it for a playback revision.
    public static func revision(of source: NativeSearchSource) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return "sha256:" + SHA256.hash(data: try encoder.encode(source))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw SourceSubscriptionBaselineError.missingResource(name)
        }
        return try Data(contentsOf: url)
    }
}
