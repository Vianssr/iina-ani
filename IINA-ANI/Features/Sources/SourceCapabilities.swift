import Foundation

/// Declared independently: resolving a URL does not imply a downloader or web player.
enum SourceCapability: String, Codable, CaseIterable, Sendable {
    case information, resolve, episodes, lines, quality, search, browse
    case iina, mpv, jsPlayer, danmaku, download

    var displayTitle: String {
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

struct SourceDescriptor: Sendable {
    let id: String
    let name: String
    let version: Int
    let capabilities: Set<SourceCapability>

    func unavailableReason(for capability: SourceCapability) -> String? {
        guard !capabilities.contains(capability) else { return nil }
        switch capability {
        case .download: return String(localized: "This source has no supported direct-file or non-DRM HLS VOD download path.")
        case .jsPlayer: return String(localized: "This source has no verified built-in web playback path.")
        case .danmaku: return String(localized: "This source has no supported danmaku provider.")
        default: return String(localized: "This source does not provide \(capability.displayTitle).")
        }
    }
}

struct SourceSearchResult: Sendable {
    let item: SourceItemRef
    let title: String
    let cover: String
    let classification: MediaClassification

    init(item: SourceItemRef, title: String, cover: String, classification: MediaClassification = .unknown) {
        self.item = item
        self.title = title
        self.cover = cover
        self.classification = classification
    }
}

struct SourceSearchPage: Sendable {
    let results: [SourceSearchResult]
    /// nil means the source has no further page, not an invented total count.
    let nextPage: Int?
}
