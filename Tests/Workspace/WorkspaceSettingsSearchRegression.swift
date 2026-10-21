import Foundation

@main
struct WorkspaceSettingsSearchRegression {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }
    static func main() {
        let font = WorkspaceSettingDestination(id: "skin.personal", group: .appearance, title: "個人字級與密度", aliases: "font text size density 字体 放大 緊湊")
        let player = WorkspaceSettingDestination(id: "playback.player", group: .playback, title: "外部播放器", aliases: "player iina mpv 播放器")
        let cache = WorkspaceSettingDestination(id: "cache.clear", group: .storage, title: "清理可重建快取", aliases: "clear cache cleanup delete 缓存 清除")
        let destinations = [font, player, cache]
        check(!cache.matches("cache mpv"), "all search tokens must match the same setting")
        check(destinations.filter { $0.matches("mpv") }.map(\.id) == ["playback.player"], "search preserves setting ID, not category ID")
        check(destinations.filter { $0.matches("not-an-existing-setting") }.isEmpty, "unknown queries do not invent fallback settings")
        check(cache.matches("  CACHE\n清除  "), "whitespace-separated query retains token matching")
        print("Workspace settings search regression passed")
    }
}
