# 修改程式與資源

先閱讀 [README](../../README.md) 的產品範圍與[架構](../architecture/PROJECT.md)的相關分層，再追蹤實際原始碼。

- 先保留現有站點、IINA／mpv、彈幕、JSPlayer、書籤及虎牙代理行為，再重構內部結構。
- 重用 `SupportSiteProtocol`、`DanmakuEvent` 等既有契約；修改時追蹤全部呼叫端與外掛協議。
- 不把改寫 SwiftUI、替換 Core Data、導入 ani-subs 或自建 TypeScript 插件當作預設任務。
- 保留上游版權、GPL 授權、圖示授權、依賴鎖檔與必要資源。不得因檔案看似舊版就刪除。
- 刪除程式前檢查 Xcode build phases、Storyboard、資源載入及 JavaScript bridge；清理後不得留下懸空引用。

新增介面字串需在對應 xcstrings 同步提供 en、zh-Hans、zh-Hant，保留插值型別與順序。Skin 新包副檔名統一為 `.aniskin`，不提供 `.iinaskin` 開啟／匯入入口；既有 manifest 最低版本不因 App 升版而提高。
