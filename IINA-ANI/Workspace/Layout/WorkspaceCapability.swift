import Foundation

/// Presentation visibility never changes this capability graph or service lifetime.
enum WorkspaceCapability: String, Codable, CaseIterable, Sendable {
    case metadata, favorites, search, playback, taskManagement
    case schedule, favoriteUpdates, recommendations, downloads, danmaku

    var dependencies: Set<Self> {
        switch self {
        case .metadata, .taskManagement: return []
        case .favorites, .search, .schedule: return [.metadata]
        case .playback: return [.taskManagement]
        case .favoriteUpdates: return [.favorites, .metadata]
        case .recommendations: return [.metadata]
        case .downloads: return [.taskManagement]
        case .danmaku: return [.playback]
        }
    }

    var canDisable: Bool {
        switch self {
        case .schedule, .favoriteUpdates, .recommendations, .downloads: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .metadata: return String(localized: "作品資料")
        case .favorites: return String(localized: "收藏保存")
        case .search: return String(localized: "搜尋／開啟")
        case .playback: return String(localized: "播放")
        case .taskManagement: return String(localized: "活動任務管理")
        case .schedule: return String(localized: "排期刷新")
        case .favoriteUpdates: return String(localized: "收藏更新刷新")
        case .recommendations: return String(localized: "Bangumi 趨勢推薦")
        case .downloads: return String(localized: "新增／恢復下載")
        case .danmaku: return String(localized: "彈幕")
        }
    }

    var disableUnavailableReason: String? {
        canDisable
            ? nil
            : self == .danmaku
                ? String(localized: "外部播放器的活動彈幕生命週期無法完整追蹤；請使用既有播放設定，工作區不提供不安全的服務停用。")
                : String(localized: "基礎能力不能隨工作區停用。")
    }
}

struct WorkspaceCapabilityFailure: Error, LocalizedError, Sendable {
    let reasons: [String]
    var errorDescription: String? { reasons.joined(separator: "\n") }
}

struct DiscoveryRefreshPolicy: Equatable, Sendable {
    var schedule = true
    var favoriteUpdates = true
    var recommendations = true
}
