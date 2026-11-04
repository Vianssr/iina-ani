import Foundation

/// Declared independently: resolving a URL does not imply a downloader or web player.
public enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case information, resolve, episodes, lines, quality, search, browse
    case iina, mpv, jsPlayer, danmaku, download

    public var displayTitle: String {
        switch self {
        case .information: return String(localized: "Information")
        case .resolve: return String(localized: "URL Resolution")
        case .episodes: return String(localized: "Episodes")
        case .lines: return String(localized: "Playback Lines")
        case .quality: return String(localized: "Quality")
        case .search: return String(localized: "Search")
        case .browse: return String(localized: "Browse")
        case .iina: return "IINA"
        case .mpv: return "mpv"
        case .jsPlayer: return String(localized: "Web Player")
        case .danmaku: return String(localized: "Danmaku")
        case .download: return String(localized: "Downloads")
        }
    }
}

public enum SourcePlatform: String, CaseIterable, Sendable {
    case macOS, iOS

    /// Backends supported by the platform, not permissions granted by a configuration.
    public var capabilities: Set<SourceCapability> {
        switch self {
        case .macOS: return Self.desktopCapabilities
        case .iOS: return Self.mobileCapabilities
        }
    }

    private static let desktopCapabilities = Set(SourceCapability.allCases)
    private static let mobileCapabilities: Set<SourceCapability> = [
        .information, .resolve, .episodes, .lines, .search, .mpv
    ]
}

public struct SourceDescriptor: Sendable {
    public let id: String
    public let name: String
    public let version: Int
    public let capabilities: Set<SourceCapability>

    public init(id: String, name: String, version: Int, capabilities: Set<SourceCapability>) {
        self.id = id
        self.name = name
        self.version = version
        self.capabilities = capabilities
    }

    public func unavailableReason(for capability: SourceCapability) -> String? {
        guard !capabilities.contains(capability) else { return nil }
        switch capability {
        case .download: return String(localized: "This source has no supported direct-file or non-DRM HLS VOD download path.")
        case .jsPlayer: return String(localized: "This source has no verified built-in web playback path.")
        case .danmaku: return String(localized: "This source has no supported danmaku provider.")
        default: return String(localized: "This source does not provide \(capability.displayTitle).")
        }
    }
}

public struct SourceSearchResult: Sendable {
    public let item: SourceItemRef
    public let title: String
    public let cover: String
    public let classification: MediaClassification

    public init(item: SourceItemRef, title: String, cover: String, classification: MediaClassification = .unknown) {
        self.item = item
        self.title = title
        self.cover = cover
        self.classification = classification
    }
}

public struct SourceSearchPage: Sendable {
    public let results: [SourceSearchResult]
    /// nil means the source has no further page, not an invented total count.
    public let nextPage: Int?

    public init(results: [SourceSearchResult], nextPage: Int?) {
        self.results = results
        self.nextPage = nextPage
    }
}
