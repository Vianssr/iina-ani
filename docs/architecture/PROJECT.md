# IINA-ANI 架構

IINA-ANI 是以 Swift、AppKit、Core Data 與 WebKit 組成的 macOS 影音工作區，整合作品資訊、來源解析、播放、彈幕、收藏與下載。

## 工程與分層

主工程為 `IINA-ANI.xcodeproj`，target 與 scheme 為 `IINA-ANI`，Swift module 為 `IINA_ANI`。`App`、`Workspace`、`Features`、`Infrastructure` 與 `Shared` 是同一 module 內的功能分層；`HuyaKit` 為獨立 Swift Package，`Native` 提供原生核心與輔助程式。

```mermaid
flowchart TD
    App[App：啟動與服務組裝] --> Workspace[Workspace：視窗、面板、佈局與外觀]
    App --> Features[Features：業務服務]
    Workspace --> Features
    Features --> Infrastructure[Infrastructure：儲存、HTTP 與快取]
    Features --> HuyaKit[HuyaKit：虎牙串流代理]
    Features --> Torrent[Native：Torrent 核心]
    Workspace --> LayoutScript[Native：LayoutScript helper]
```

`Shared` 提供各層共用的 extensions、日誌、識別常數、限流與計時工具。

## 目錄結構

| 路徑 | 職責 |
| --- | --- |
| `IINA-ANI/App/` | AppDelegate、AppServices、Preferences 與 MainMenu |
| `IINA-ANI/Workspace/Shell/` | 工作區入口、主視窗、頁面渲染、導覽、轉場與組件呈現狀態 |
| `IINA-ANI/Workspace/Panels/` | 搜尋、發現、詳情、收藏、下載、Torrent 與截圖識圖面板 |
| `IINA-ANI/Workspace/Settings/` | 偏好設定介面、設定搜尋與外掛設定 |
| `IINA-ANI/Workspace/Layout/` | 頁面與節點模型、組件登記、能力、驗證、編排、交易、保存與腳本執行 |
| `IINA-ANI/Workspace/Skin/` | 主題模型、封裝、驗證、保存、樣式解析與外觀控制 |
| `IINA-ANI/Features/Accounts/` | 站點帳號、OAuth、Cookies、Keychain 與登入介面 |
| `IINA-ANI/Features/Bangumi/` | Bangumi 模型、查詢與作品同步 |
| `IINA-ANI/Features/Discovery/` | 搜尋、推薦聚合、Bilibili 動態、YouTube 瀏覽與 trace.moe 識圖 |
| `IINA-ANI/Features/Sources/` | 來源登記、能力、配置、訂閱、選擇與統一媒體結果；`Decoders/` 存放解析器 |
| `IINA-ANI/Features/Playback/` | 播放協調、播放器參數、進度與歷史；`Danmaku/`、`JSPlayer/`、`OpenFiles/` 分別處理彈幕、網頁播放器及本機影片入口 |
| `IINA-ANI/Features/Downloads/` | 下載任務、來源解析、直連與 HLS 後端 |
| `IINA-ANI/Features/Torrent/` | 原生 session、RSS 搜尋、metadata、下載後端、HTTP Range 與串流播放 |
| `IINA-ANI/Infrastructure/Persistence/` | 作品、集數、來源映射、收藏、書籤、遷移與儲存路徑 |
| `IINA-ANI/Infrastructure/HTTP/` | 本機 HTTP、WebSocket 與虎牙路由 |
| `IINA-ANI/Infrastructure/Cache/` | 圖片快取 |
| `IINA-ANI/Shared/` | 跨功能共用工具 |
| `IINA-ANI/Core Data/` | 版本化資料模型 |
| `IINA-ANI/Assets/`、`Sources/`、`WebFiles/` | 圖像、來源 JSON 與網頁資源 |
| `HuyaKit/` | 虎牙串流套件與 `huyaproxy` CLI |
| `Native/` | Torrent C ABI、C++ 核心、建置腳本與 LayoutScript helper |
| `Config/` | Xcode 配置與本機配置範本 |
| `Tests/` | 按功能分類的回歸程式、fixtures 與 `run-*.sh` 執行入口 |
| `Examples/`、`Design/` | Skin／頁面動效範例與設計素材 |
| `docs/` | 使用指南、Skin 指南、架構文件與工作記錄 |

## 應用組裝與生命週期

`AppDelegate` 負責應用啟動、選單、工作區入口與關閉流程，持有 `AppServices` 和 `LibraryPersistence`；作品庫、收藏庫由後者統一組裝，書籤 DataManager 注入其共用 context 與收藏庫。

`AppServices` 是服務組裝根，注入 `Preferences`、`SourceRegistry`、`SiteAccounts` 與儲存路徑，組裝 `VideoDecoder`、`Processes`、`HttpServer` 和 `TorrentStreamingService`，按需建立 `DownloadService` 與 `PlaybackHistoryStore`。內建 JSPlayer 視窗也由此持有。

工作區 controller 持有目前頁面、選擇、分頁游標及查詢任務。已提交的下載與播放由應用層服務持有；面板移除時釋放其查詢和呈現狀態。AppKit 呈現與服務組裝主要位於 `MainActor`；`SiteAccounts`、`DownloadService` 及站點 actor 管理各自的非同步狀態。

## 工作區結構

### 主殼與產品面板

`WorkspaceApplicationController` 組裝工作區依賴與固定操作入口。主視窗協調側欄、頁面導覽與詳情轉場，`WorkspaceRenderer` 將 Layout 節點轉換為容器與產品面板。

主要面板分工如下：

- `WorkspaceServicePanelController`：發現、搜尋、站點瀏覽、下載與繼續觀看等服務介面。
- `WorkspaceDetailController`：作品與來源詳情、選集、評論、資訊子頁，以及來源／管理窗口。
- `WorkspaceFavoritePanelController`：作品收藏、連結收藏與更新資訊。
- `WorkspaceQuickDownloadController`：在線來源解析、批次選集與下載提交。
- `WorkspaceTorrentController`：Torrent 搜尋、匯入、metadata 與檔案選取。
- `ImageSearchWindowController`：本機圖片準備、辨識查詢與結果操作。

詳情主頁與資訊子頁各自持有捲動視圖，共用作品與查詢狀態。`WorkspaceDetailTransition` 處理封面轉場；`WorkspaceFeedGridLayout` 負責推薦網格的欄位與卡片座標。

### Layout、Skin 與呈現狀態

| 結構 | 內容 | 主要實作 |
| --- | --- | --- |
| Layout | 頁面、容器、組件實例、尺寸、斷點與頁面動效 | `WorkspaceModel`、`WorkspaceRegistry`、`WorkspaceValidation`、`WorkspaceTransactions`、`WorkspaceStore` |
| 編排草稿 | 編輯中的節點、操作紀錄與保存交易 | `WorkspaceLayoutEditor`、`WorkspaceLayoutEditorController` |
| Skin | 色彩、字型、密度、素材、組件狀態樣式與個人覆寫 | `SkinModel`、`SkinPackageValidator`、`SkinArchive`、`SkinStore`、`SkinAppearance` |
| 組件呈現狀態 | 各組件實例的查詢、篩選、分頁、選擇、捲動位置與密度 | `WorkspaceSessionState` |
| 應用偏好 | 語言、播放、彈幕、來源、下載與詳情顯示設定 | `Preferences` |

Layout 編排經驗證與交易保存。Skin 套件由封裝與儲存層管理，`SkinAppearance` 將主題及個人覆寫解析為 AppKit 樣式。LayoutScript 由獨立 helper 執行，結果送回 Layout 處理流程。

## 業務服務與資料流

### 搜尋與作品資訊

`BrowseSearchService` 整合 Bangumi 搜尋、來源搜尋與網址解析；`DiscoveryService` 聚合日常推薦及放送資訊。`BangumiService` 提供作品、集數、人物、關聯與評論資料，`BangumiWorkSync` 將作品資訊接入本機作品庫。

`SourceRegistry` 保存來源描述與能力；`SourceSubscriptionService` 處理訂閱配置，來源搜尋使用已套用的規則。`AnimeSourceService` 結合作品、集數與來源映射尋找候選。

Bilibili 動態及 YouTube 瀏覽使用各自的服務。`TraceMoeSearchService` 接收準備完成的圖片並返回辨識候選，結果由窗口送往作品搜尋、AniList 或預覽入口。

### 解析與播放

網址或作品選擇經 `VideoDecoder` 分派至站點解析器，產生 `YouGetJSON`／`Stream`；`PlayableSelection` 記錄來源、集數、線路與品質選擇。`PlaybackEncoder` 負責播放器參數編碼，`Processes` 協調解析後的媒體、彈幕及 IINA／mpv 啟播。

內建 JSPlayer 透過 WebKit 載入網頁播放器。播放進度回傳至 `PlaybackHistoryStore`；續看由 `AppServices.resumePlayback` 依保存的選擇重新取得媒體並定位播放時間。

直播彈幕轉為 `DanmakuEvent`，經本機 WebSocket 傳往 IINA 彈幕外掛，或經 JavaScript bridge 送入 JSPlayer；點播彈幕使用 XML 檔案。虎牙串流由 `HuyaKit` 解析 `.slice`，經本機 FLV 代理提供給播放器。

### 帳號與請求上下文

`SiteAccounts` 管理帳號紀錄、預設帳號、驗證狀態及使用 lease。帳號 metadata 存於 UserDefaults，Cookies 與 OAuth 憑證存於 Keychain。

來源操作透過 `withSource`／`withAccount` 建立 `AccountHTTP.Context`，將來源身份、帳號與請求憑證傳入非同步操作。`BangumiOAuth` 處理 OAuth，`YouTubeBrowserCookies` 與 `YouTubeCookieImport` 處理瀏覽器及檔案的 Cookies 匯入。

### 下載與 Torrent

`DownloadSourceResolver` 將來源選擇轉為下載輸入，`DownloadService` 持有任務紀錄、執行狀態、帳號 lease 與恢復流程。直連下載交由 `DirectDownloader`，HLS 交由 `HLSDownloader`，並透過 FFmpeg 封裝輸出。

Torrent 搜尋由 `TorrentSearchService` 讀取 RSS 配置。匯入與檔案選取取得 metadata 後，下載後端經 C ABI 呼叫 `Native` 中的 libtorrent 核心；同一 Torrent 的檔案任務共用底層傳輸。`TorrentStreamingService` 結合本機 HTTP Range 路由，將選定檔案提供給外部播放器。

## 資料模型與儲存

`LibraryPersistence` 封裝 Core Data container、載入錯誤、遷移前備份、書籤排序／收藏／作品分類遷移及退出前保存。儲存 URL 由 `AppStoragePaths.libraryStoreURL` 決定；測試可注入獨立 URL 與模型，初始化失敗不提供部分可用的資料庫，也不退回空白或暫存資料庫。

`WorkLibrary` 與 `FavoriteLibrary` 注入同一個 main-queue context，收藏庫重用同一個作品庫；收藏面板的變更通知僅監聽所屬 context。業務方法仍負責各自保存／回滾，這次未改為全域延遲提交。

`WorkLibrary` 管理 `Work`、`Episode`、`WorkSourceLink` 與 `EpisodeSourceMapping`：作品包含集數，來源連結指向站點作品，集數映射連接本機集數與可播放選擇。`FavoriteLibrary` 管理作品收藏與連結收藏。

Core Data 模型位於 `Core Data/DataModel.xcdatamodeld`，目前模型為 `Library v0.5`，包含 `Bookmark`、`WorkRecord`、`EpisodeRecord`、`WorkSourceLinkRecord` 與 `WorkFavoriteRecord`；舊版本模型供遷移使用。

| 資料 | 儲存位置或機制 |
| --- | --- |
| 作品、集數、來源映射與收藏 | Core Data，位於 `Application Support/IINA+` |
| 偏好與帳號 metadata | UserDefaults |
| 帳號 Cookies、OAuth 憑證 | Keychain |
| 工作區佈局 | `Workspace/layout-v1.json` |
| 組件呈現狀態 | `Workspace/instance-state-v1.json` |
| Skin 套件與配置 | `Skins/` |
| 播放歷史 | `Playback/history-v1.json` |
| 下載任務 | `Downloads/tasks-v1.json` |
| 下載暫存與預設完成目錄 | `Downloads/Temporary/`、`Downloads/Completed/` |

上述 JSON、Skin 與下載路徑相對於應用的 Application Support 根目錄；`AppStoragePaths` 依 Bundle ID 建立該根目錄，目前為 `com.LlS.iina-ani`。

## 套件與資源組成

Swift 依賴由 Xcode 的 Swift Package Manager 整合，`HuyaKit/Package.swift` 定義虎牙 library 與 `huyaproxy` executable。`Native` 的 C++ 核心透過 `TorrentBridge.h` 與 Swift 交換 session、metadata、檔案及傳輸狀態。

`WebFiles/package.json` 管理網頁播放器與彈幕所需的 JavaScript 資源；`InstallDeps.sh` 準備這些資源與外部 IINA 彈幕外掛。圖像位於 `Assets/`，來源規則位於 `Sources/`，本地化字串由字串目錄及各網頁／Storyboard 資源提供。

`Config/App.xcconfig` 載入本機配置，將 Bangumi OAuth 應用設定注入 Info.plist。Xcode 建置階段同時整合 Torrent 原生核心與 LayoutScript helper。

Bundle ID 變更未包含自動資料遷移：舊 Bundle ID 目錄中的 Layout、Skin、播放歷史與下載任務不會自動轉入新目錄；UserDefaults 與帳號 Keychain service 亦隨 Bundle ID 改變。Core Data 仍使用上述 `Application Support/IINA+`，因此不能視為已與上游完整隔離。
