import Foundation

enum WorkspaceSettingsGroup: String, CaseIterable {
    case appearance = "外觀與佈局", sources = "來源與帳號", playback = "播放與彈幕"
    case storage = "下載與儲存", about = "關於"
    var displayTitle: String {
        switch self {
        case .appearance: return String(localized: "外觀與佈局")
        case .sources: return String(localized: "來源與帳號")
        case .playback: return String(localized: "播放與彈幕")
        case .storage: return String(localized: "下載與儲存")
        case .about: return String(localized: "關於")
        }
    }
    var aliases: String {
        switch self {
        case .appearance: return "appearance layout skin theme 外观 布局 皮肤 主題"
        case .sources: return "sources accounts login cookie 來源 源 帐号 登录 授權"
        case .playback: return "playback player danmaku 播放器 弹幕"
        case .storage: return "download storage cache 下载 存储 缓存"
        case .about: return "about version license 关于 版本 授權"
        }
    }
}

/// Search carries a concrete setting identity, including dynamic sources/accounts.
/// Category aliases match all its settings without replacing those identities.
struct WorkspaceSettingDestination {
    let id: String
    let group: WorkspaceSettingsGroup
    let title: String
    let aliases: String
    func matches(_ query: String) -> Bool {
        let haystack = "\(title) \(aliases) \(group.rawValue) \(group.displayTitle) \(group.aliases)"
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return query.split(whereSeparator: { $0.isWhitespace }).allSatisfy {
            haystack.contains(String($0).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current))
        }
    }
}
