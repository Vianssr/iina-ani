import Foundation
import SourceCore

/// Public search metadata only. Native playback adapters and their revisions stay local.
public struct NativeSearchSource: Codable, Sendable {
    public let hosts: [String]
    public let search: SourceConfiguration.Search
    public let resultURLTemplate: String?

    public init(hosts: [String], search: SourceConfiguration.Search, resultURLTemplate: String? = nil) {
        self.hosts = hosts
        self.search = search
        self.resultURLTemplate = resultURLTemplate
    }
}

public struct SourceSubscriptionPlan: Codable, Sendable {
    public let fingerprint: String
    public let checkedAt: Date
    public let overrides: [String: Data]
    /// Explicit v4 static-page configurations; never masquerade as native adapters.
    public let configurations: [String: Data]
    public let entries: [SourceSubscriptionEntry]

    public init(fingerprint: String, checkedAt: Date, overrides: [String: Data], entries: [SourceSubscriptionEntry], configurations: [String: Data] = [:]) {
        self.fingerprint = fingerprint
        self.checkedAt = checkedAt
        self.overrides = overrides
        self.configurations = configurations
        self.entries = entries
    }

    private enum CodingKeys: String, CodingKey { case fingerprint, checkedAt, overrides, entries, configurations }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fingerprint = try c.decode(String.self, forKey: .fingerprint)
        checkedAt = try c.decode(Date.self, forKey: .checkedAt)
        overrides = try c.decode([String: Data].self, forKey: .overrides)
        entries = try c.decode([SourceSubscriptionEntry].self, forKey: .entries)
        configurations = try c.decodeIfPresent([String: Data].self, forKey: .configurations) ?? [:]
    }
}

public struct SourceSubscriptionEntry: Codable, Sendable {
    public let sourceID: String?
    public let name: String
    public let status: String
    public let detail: String

    public init(sourceID: String?, name: String, status: String, detail: String) {
        self.sourceID = sourceID
        self.name = name
        self.status = status
        self.detail = detail
    }
}

public enum SourceSubscriptionError: Error, LocalizedError, Equatable {
    case tooLarge, malformed, tooManyItems

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return String(localized: "來源訂閱超過 2 MiB 上限。")
        case .malformed: return String(localized: "來源訂閱格式無效，應包含 mediaSources 或 exportedMediaSourceDataList.mediaSources。")
        case .tooManyItems: return String(localized: "來源訂閱超過 128 個項目上限。")
        }
    }
}
