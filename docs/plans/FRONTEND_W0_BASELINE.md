# W0 基線與資料盤點

> 2026-10-07；狀態：**已驗收（W0）**。對應 [FRONTEND_REFACTOR_PLAN.md](FRONTEND_REFACTOR_PLAN.md) §5.1。
> W0 盤點包沒有修改 App 原始碼、工程、模型或播放器協議；已驗收的是盤點、可還原資料副本與舊介面證據，不是所有站點／播放器均可用。§1–§7 是當時快照；後續既存修復及未解限制見 §8。W1、W3 已驗收，W2 基礎實作交付／真實登入驗收待補，另見 [重構文檔](FRONTEND_REFACTOR_PLAN.md) §5.1；W4–W10 未開始。

## 1. 證據與判定規則

- 原始碼基線：`IINA+/`、`IINA+.xcodeproj/`、`HuyaKit/` 共 200 個檔案的 SHA-256 清單，保存於 `.build/w0/evidence/source-manifest.json`；排除建置、node_modules、個人 Xcode 設定及下載外掛包。這是目前 fork 的基線，不冒充匯入時的上游 commit。
- 建置：Xcode 27.0／Swift 6.4，Debug、arm64、無正式簽署，`BUILD SUCCEEDED`。既存 `Preferences` storyboard 無入口的警告仍在。
- 執行：由本次 `.build/xcode/Build/Products/Debug/IINA+.app` 複製隔離產物，只變更測試副本 Bundle ID 為 `org.iina-ani.w0-baseline` 並 ad-hoc 重簽。程式來自同一次建置；重簽後二進位雜湊不與原產物相同，未宣稱位元組一致。
- 歷史證據以 [WORK_LOG.md](../history/WORK_LOG.md) 原文為準。本次連線、媒體解碼及 UI 操作另列於 §5，不能互相替代。
- LSP 可取得 `Processes`／`YouGetJSON` 的符號；對 `Processes.decodeURL`、`VideoDecoder.decodeUrl` 的 references 查詢均回無結果，不能宣稱編譯器確認了全部呼叫端。入口另由原始碼、Storyboard 連接、資源相位及實際 UI 核對。
- **歷史失效**：W0 前工作記錄已載明；**W0 既存缺口**：在未改 App 的這次基線上發現；**未驗證**：缺少執行證據，不能標為失效；**回歸**：後續變更使同一條已通過的基線路徑失敗。易變站點需同時記錄頁面、集數、線路與網路狀態，不能只憑今天失敗推定回歸。

## 2. 來源／播放器能力矩陣

圖例：`外部` 指原始碼提供 IINA／mpv 路徑，**不代表實際播放器載入通過**；`XML` 為 B 站點播彈幕；`WS` 為直播彈幕。下表的能力來自原始碼。`H-P`＝歷史實際 Swift 解析器；`H-M`＝歷史媒體探測／解碼，可能僅從頁面取址；`H-A`＝歷史 App／loopback／UI 證據；`未驗`＝工作記錄未提供該來源的執行證據。歷史完整 App 建置不等於 H-A。

### 2.1 點播來源

| source／適配器 | 網域／頁面身份 | 選集、線路、品質 | 外部 | JSPlayer／站方彈幕 | 請求／媒體邊界 | 歷史程度 |
| --- | --- | --- | --- | --- | --- | --- |
| `xiFan`／XiFan | `dm1.xfdm.pro`；`/bangumi/{id}.html`、`/watch/{id}/{line}/{ep}.html` | 多線多集；線路作 streams key | 有 | 無／無 | 公開未加密 HTTPS MP4／HLS／FLV | 未驗 |
| `girigiri`／Girigiri | `ani.girigirilove.com`；`/GV{id}/`、`/playGV{id}-{line}-{ep}/` | 多線多集；保留 line／episode 編號 | 有 | 無／無 | player_aaaa 0/1/2 編碼；拒絕付費／試看；HTTPS MP4／HLS | H-P、H-M（HLS 200／ffprobe，非視窗播放） |
| `didahd`／Didahd＋DidahdProxy | `didahd.pro`、`didahd.xyz`（www／裸域）；detail／play | 多線多集；僅可解析線入選單 | 有 | 無／無 | 4kvm token 經 WebKit 解址；loopback HLS PNG→TS；其他加密線／網盤未支援 | H-P、H-M、H-A；使用者另確認可播，播放器未指定 |
| `jibi`／Jibi | `jibi.cc`（www／裸域）；index.php/vod 的 id／sid／nid | 多線多集；sid 不等於列表位置 | 有 | 無／無 | 未加密 HTTPS MP4／HLS | H-P、H-M |
| `eacg`／EACG | `eacg1.com`（www／裸域）；voddetail／vodplay | 多線多集 | 有 | 無／無 | fed-play-iframe 編碼；公開 HTTPS MP4／HLS | H-P、H-M |
| `senfun`／Senfun | `senfun.in`；作品 id＋ep slug | 集目錄；逐集 API 多線；保留 ep1_02／ep1a 等 slug | 有 | 無／無 | `/_senfun_plays/{id}/{slug}`；HTTPS MP4／HLS | H-P、H-M；部分線歷史失效見 §6 |
| `kanba`／Kanba | `11kt.net`、`qkan8.com`（各 www／裸域）；index.php/vod 的 id／sid／nid | 多線多集；跨線依 nid 對集 | 有 | 無／無 | data-play 鹽／base64 編碼；HTTPS MP4／HLS；各線編號不同步有錯集風險 | H-P、H-M |
| `haixing`／Haixing | `haixingdmx.com`（www／裸域）；view／play | 多線多集；線路Ⅰ–Ⅵ | 有 | 無／無 | /playinfo Cookie 挑戰；專屬停用 Cookie 儲存的 URLSession；UA／Referer；MP4／HLS／FLV／MKV | H-P、H-M；非 ASCII URL 的站方重複編碼差異已記錄 |
| `yinghua`／Yinghua | `yinghuaaa.com`、`yinghua2.com`（各 www／裸域）；index.php/vod | 多線多集；跨線依集標題／第 N 集而非陣列下標 | 有 | 無／無 | 未加密 HTTPS MP4／HLS | H-P、H-M；六線中兩線 TLS EOF |
| `dilidili`／Dilidili | `dilidili.io`（www／裸域）；anime／watch slug | 集目錄；逐集多線 | 有 | 無／無 | `/_get_play`；公開 MP4／HLS | H-M；完整 Swift actor 全鏈未證明 |
| `youknow`／Youknow | `youknow.tv`（www／裸域）；`/d/{id}/`、`/p/{id}-{line}-{ep}/` | 多線多集 | 有 | 無／無 | player_aaaa 0/1/2；公開 MP4／HLS | H-M；完整 Swift actor 全鏈未證明 |
| `fqdm`／Fqdm | `fqdm.cc`（www／裸域）；index.php/vod | 多線多集 | 有 | 無／無 | player_aaaa 0/1/2；公開 MP4／HLS | H-M；完整 Swift actor 全鏈未證明 |
| `hanime1`／Hanime1 | `hanime1.me`（www／裸域）；`/watch?v={id}` | 單片，無集數樹；如 1080p／720p | 有 | 無／無 | video source；僅公開 MP4 | H-M；完整 Swift actor 全鏈未證明 |
| `wedm`／Wedm | `vdm5.com`（www／裸域）；vodetail／dmplay | 多線多集；作品 id 可為字母數字 | 有 | 無／無 | player_aaaa 0/1/2；公開 MP4／HLS | H-M；完整 Swift actor 全鏈未證明 |
| `forest`／Forest | `hc34567.com`（www／裸域）；hcvoddetail／hcvodplay | 多線多集 | 有 | 無／無 | player_aaaa 0/1/2；公開 MP4／HLS | H-M；完整 Swift actor 全鏈未證明 |
| `fengche`／Fengche | `dongmandaquan.vip`（www／裸域）；voddetail／vodplay | 多線多集；UI 缺口見 §6 | 有 | 無／無 | player_aaaa 0/1/2；公開 MP4／HLS；騰訊外部頁面不作媒體 | H-P、H-M |

### 2.2 直播與 Bilibili／特殊入口

| source／適配器 | 網域／身份、選擇 | 外部 | JSPlayer | 彈幕 | 必須保留的邊界 | 歷史程度 |
| --- | --- | --- | --- | --- | --- | --- |
| `biliLive`／BiliLive | `live.bilibili.com/{rid}`；房間／品質／codec | 有 | 有 | WS | FLV／fMP4；需 uid／token；密碼房拒絕；二階段品質解析 | 未驗 |
| `douyu`／Douyu | `douyu.com`（www／裸域）；房間／multirates／CDN | 有 | 有 | WS | JS 簽名／md5；登入 dy_auth／acf_auth 共享 Cookie；賽事子房缺口見 §6 | 未驗 |
| `huya`／Huya＋HuyaKit | `huya.com`（www／裸域）；房間、服務端碼率／線路順序 | 有 | 有 | WS | 外部播放必走 `/huya/{uuid}.flv`；slice→FLV、預熱、斷線取消；排除全 HDR，等效碼率可偏好 265 | 未驗 |
| `cc163`／CC163 | `cc.163.com`、`ds.163.com`；多種 room／channel／ccid | 有 | 有 | 無實作 | FLV CDN、ds appKey；房間解析／跳轉邊界 | 未驗 |
| `douyin`／DouYin | `live.douyin.com/{rid}`；www／裸域 douyin 的 live 路徑正規化 | 有 | 有 | WS | ttwid／msToken／a_bogus、douyin.js、protobuf；一般影片不支援 | 未驗 |
| `qieTV`／QieTV | `qie.tv`（www／裸域）、`live.qq.com`；單一 Default | 有 | 有 | 部分程式存在，未驗可達播放全鏈 | API→NEXT_DATA 回退；JSPlayer 未呼叫其 startDM | 未驗 |
| `bilibili`／BiliVideo | bilibili.com（www／裸域）；BV／av、分 P／合輯 | 有 | 無 | XML | API／HTML 回退；audio 獨立、UA／Referer；DASH 註冊開關關閉 | 未驗 |
| `bangumi`／BiliBangumi | 同 B 站；`/bangumi/play/ep…`／ss…、ep ID | 有 | 無 | XML | PGC 品質／VIP 錯誤；這不是 bgm.tv 元資料服務 | 未驗 |
| `b23` | b23.tv 短鏈，無独立 adapter | 解址後沿用 B 站 | 無 | 同目的來源 | 主 UI formatter 跟隨轉址；直接 decode／HTTP 不替它解址 | 未驗 |
| `local` | OpenFiles 的本機檔案，非網址分類的站點 | 有 | 無 | 可配本機 XML；自動下載受 id=-1 擋下 | 不經 VideoDecoder.decodeUrl；媒體檔與 XML 分開選取 | 未驗 |
| `unsupported` | 無匹配的網域／路徑 | 無有效路徑 | 不列為支援來源 | 無保證 | decode 丟 notSupported；supportWebPlayer 是否定清單，不能用它單獨證明來源可播 | 未驗 |

以上涵蓋 `SupportSites` 的全部 27 case。來源搜尋、Bangumi 元資料、真實下載管理器與帳號池尚未存在；取得媒體 URL 不等於具備下載能力。

### 2.3 共同播放器／狀態邊界

- `Processes` 持有 `videoDecoder`、`iina`、`httpServer`、`decodeTask`；`decodeURL` 先取消前一解析任務。主 UI 還持有 isSearching／yougetResult／waitingErrorMessage；HTTP 是另一條直接 decoder 路徑，不能稱現況已統一。
- 主 UI：`startSearchingUrl` → formatter → 各站選集前置 → `liveInfo`／`Processes.decodeURL` → 結果列 → `open(result:row:)` → 品質補解析／彈幕準備／播放器。JSPlayer 在 enableFlvjs 且來源可用時提前分支。
- 普通 IINA（build≥90）及外掛版使用 URL scheme；旧版 IINA／IINA-Danmaku 可走 CLI；mpv 走子行程及 customMpvPath／which。不能用 scheme 開啟成功推定媒體載入。
- 點播 XML 下載只在非 normal IINA、enableDanmaku、livePlayer=IINA、site 屬 bilibili／bangumi／local 且 id!=-1 時運行；16 個新增點播站點不啟動站方彈幕。
- 主 UI 無論選 IINA 或 mpv 都先檢查 IINA 彈幕外掛，缺少／需更新時中止解析。乾淨隔離 home 先呈現此門檻；本次只複製已安裝的真實外掛 0.1.21／127 到隔離 home，未安裝或修改使用者的外掛。
- `[INFERENCE]` `MainViewController.open(result:row:)` 在已快取 archiveType=.plugin、IINA 且未啟內建播放器時，guard 通過後只剩註解，沒有呼叫 openWithPlayer（801–860）。此為靜態既存風險，未實測這個播放狀態轉移，後續不得遺漏。

證據：`Utils/VideoDecoder/SupportSites.swift`、`VideoDecoder.swift:43–197,199–282`、各同名 adapter；`Utils/Processes.swift:84–189`、`YouGetJSON.swift:154–316`；`Views/MainWindow/MainViewController.swift:426–860`；`Views/JSPlayer/JSPlayerViewController.swift`；`Utils/Danmaku/`。

## 3. 入口與服務遷移位置

以下是逐入口切換位置，不新增空服務。W1 演進既有解析／身份契約；W2 管偏好／帳號／快取；W3 收斂來源分派；W5 管收藏；W7 管 URL／關鍵詞及功能用例；W9 只綁定服務；W10 清除該入口舊 UI／資源。現有本機檔、播放器與彈幕的生命週期繼續由既有實作承擔。

| 入口 | 現在 call chain／狀態擁有者 | 遷移位置與不能丟的行為 |
| --- | --- | --- |
| About、Settings、外掛狀態按鈕 | MainMenu.about／preferences、MainViewController.openPreferences → WindowManger → 4 個 SwiftUI pane | W2 設定用例，W9 新設置頁；W10 移除已替代連接；版本／外掛狀態保留 |
| Check For Update | Sparkle checkForUpdates，AppDelegate updater | 發佈安全邊界；W10 獨立 feed／公鑰或停用；W0 不觸發更新 |
| Services／Hide／Hide Others／Show All／Quit | AppKit；Quit → AppDelegate.applicationShouldTerminate 保存 Core Data | W9／W10 保留視窗及保存生命週期 |
| File Open／⌘O | Main.storyboard show segue → OpenFilesWindow → select／getVideo／getDanmaku → Processes.openWithPlayer | W1 解析邊界，W9 開檔 UI；本機影片＋XML、B 站 ID 輸入不刪；本次實際打開 OpenFiles 視窗 |
| File Close／⌘W、Open Recent／Clear Menu | AppKit；NSDocument 標準 responder，未有文件架構；reopen → MainWindowController | W9／W10 視窗路由；空的文件選單不冒充業務功能 |
| File Save／Save As／Revert／Page Setup／Print | Storyboard 標準 selector，無 App 的文件實作；saveAction 也無選單連接 | 既存非業務入口；W10 核對後移除不適用選單，不重造文件系統 |
| Undo／Redo | MainMenu → persistentContainer.viewContext.undoManager；只在主視窗可用 | W5 收藏命令，W9 選單狀態；保存撤銷語義 |
| Cut／Copy／Paste／Paste and Match Style／Delete／Select All | AppKit First Responder（文字欄） | W9 原生文字操作，不能改成直接操作收藏 |
| Reload／⌘R | MainMenu → reloadMainWindowTableView 通知 → MainViewController.reloadTableView → DataManager 或 BilibiliDynamicManger | W5 收藏刷新／W7 發現用例；標題隨書籤／動態分頁更換 |
| Full Screen／Minimize／Zoom／Bring All to Front | AppKit NSWindow 標準動作 | W9／W10 保留原生視窗行為 |
| Help、Log File | MainMenu → NSWorkspace.open（上游 GitHub／AppDelegate.logUrl） | W9／W10 保留幫助及去敏日誌入口；未捏造 fork 地址 |
| 側欄書籤／搜尋／登入後動態 | SidebarViewController → sideBarSelectionChanged → MainViewController.selectTabItem／reload | W9 路由；分頁資料改消費 W5／W7；W10 清通知與舊控制器 |
| 網址欄、Return、取消 | startSearch → startSearchingUrl → stopDecodeURL、formatter、外掛檢查、decodeUrl | W1 共同解析／取消，W3 來源能力，W7 URL／關鍵詞用例，W9 薄搜尋框 |
| Esc 返回上一分頁 | MainViewController 的 keyCode=53 local monitor | W9 頁面返回與焦點；目前無全域⌘F，不誤稱已支援 |
| b23／festival 網址 | VideoDecoder.bilibiliUrlFormatter → BilibiliUrl.fUrl | W1／W3 同一正規化入口；HTTP／OpenFiles 今日不完全共用此路徑 |
| 品質結果列、雙擊播放、自動開結果 | openSelectedSuggestion／open(result:row:) → prepareVideoUrl／prepareDanmakuFile → Processes | W1 選擇／結果契約，W9 播放命令；品質鍵、Option 抑制自動開啟、取消及 proxy 預熱保留 |
| 選集／分 P／直播子房 | MainViewController 各站 episodeList／B 站 getVideoList／getBangumiList → SelectVideoViewController → URL 回寫 → directly 解析 | W1 Episode 身份，W3 集目錄能力，W9 詳情選集；W10 刪除兩處逐站 switch；不能以陣列下標跨站對集 |
| 書籤新增按鈕／右鍵 Add | AddBookmark sheet → DataManager.addBookmark → Core Data → reloadBookmark | W3 規範 URL，W5 收藏用例，W9 收藏頁；既存 remark／order／原始 URL 保留 |
| 書籤雙擊、右鍵 Decode／Copy URL | sendURL／decode／copyUrl → 同一主 UI 解析或 Pasteboard | W1／W7 解析路由，W5 收藏讀取，W9 操作；不新增第二套 decoder |
| 書籤 Remove | 確認 sheet → DataManager.delete → Core Data | W5 刪收藏命令，W9 UI；不能刪下載檔或帳號 |
| 書籤拖曳排序 | bookmark.Row pasteboard → acceptDrop → DataManager.moveBookmark；有篩選時不允許拖曳 | W5 排序持久化，W9 UI；保留 Double order 及重啟排序 |
| Site／Live State 篩選、Remove Filters | SupportSites.urlFilterPredicate／MainViewController.fetchPredicate | W3 來源身份／URL 規則、W5 查詢、W9 UI；移除硬編碼 predicate 分派 |
| 書籤匯入／匯出 | **不存在**；唯一 NSOpenPanel 是媒體／彈幕選檔 | W5 遷移／還原另實作；本包只留實體資料副本，不聲稱已有匯出功能 |
| B 站動態雙擊、Copy／Decode、觸底分頁、刷新 | BilibiliDynamicManger actor＋TokenBucket → Bilibili uid／簽名／dynamicList → Diffable data source；多 P 回選集 | W2 帳號上下文，W7 發現／搜尋用例，W9 視圖；不能把動態當作已完成收藏更新比較 |
| General／Sites／Advanced／About | WindowManger → GeneralPrefsView／SitePrefsView／AdvancedPrefsView／AboutPrefsView；Preferences＋@AppStorage 共用 UserDefaults | W2 偏好／快取，W9 五組設置；W10 清 legacy AppKit 設定；保留原鍵值 |
| B 站／鬥魚登入、登出、外掛安裝／卸載、快取清理、測試按鈕 | LoginWebView → WK Cookie → HTTPCookieStorage.shared；站點 isLogin／logout；IINAApp；SDImageCache／WKWebsiteDataStore；測試頁 URL | W2 SiteAccount／憑證生命週期及可重建快取；W9 UI；W0 不登入、不清真實快取、不改 IINA 偏好 |
| 內建 JSPlayer 及靜音／音量／品質／線路／彈幕控制 | openWithJSPlayer → JSPlayer storyboard → JSPlayerViewController／plusplayer WKURLSchemeHandler | W3 來源能力，W9 播放設定；保留 WebKit／JS bridge 與關窗釋放，不替換播放器 |
| HTTP／WebSocket | AppDelegate → HttpServer → NIOHTTPServer → HTTPHandler／DanmakuSessionManager | W1／W3 解析服務切入點；W10 保留外掛協議與 loopback；詳見下表 |
| 出向 IINA scheme／CLI | YouGetJSON 編碼 → Processes → NSWorkspace 或 Process | W1 演進既有結果，不替換外部協議；W10 全 caller 回歸 |
| 入向 App URL scheme／文件關聯 | **不存在**：Info.plist 無 CFBundleURLTypes／CFBundleDocumentTypes；AppDelegate 無 open URL handler | 不是既有功能；若後續要求，由 W7／W9 定路由及 W10 切換，不在 W0 加入 |

主視窗沒有 toolbar；設定視窗有 SwiftUI Settings 的 toolbar。證據：`Views/Base.lproj/Main.storyboard` 的 mainMenu／context menu／segue；`MainMenu.swift`；`MainViewController.swift`；`SidebarViewController.swift`；`OpenFilesViewController.swift`；`WindowManger.swift`；`Core Data/DataManager.swift`。

### 3.1 HTTP／WebSocket 契約清單

| 路由／协议 | 今日行為與遷移边界 |
| --- | --- |
| GET `/video?url=…&key=…` | HTTPHandler.decode 直接 `videoDecoder.decodeUrl` → `prepareVideoUrl`，**不經 Processes.decodeTask、UI 選集、formatter 或外掛前置檢查**；W1／W3 遷入共同服務，不改 route／key 身份 |
| GET `/video?…&pluginAPI=1` | 同上，回 YouGetJSON.iinaPlusArgsString；外掛消費的編码格式保留 |
| POST `/video/danmakuurl?url=…`、`/video/iinaurl?url=…&type=…` | 參數從 query 解碼，request body 被忽略；回 scheme；現有庫內無直接 caller，不等於沒有外部使用者 |
| GET `/video.mp4` | 回 empty.m4a；不是實際影片 API；外掛以此承載彈幕選項 |
| GET `/danmaku/test.htm` | 回 bundle test.htm，General 的 Test In Browser 使用 |
| GET `/huya/{roomID或uuid}.flv` | HuyaProxyServer，預熱與斷開上游取消；不能移除媒体代理 |
| GET `/didahd/{id}/index.m3u8`、`/{n}.ts` | DidahdProxy 的 PNG→TS 路徑；同上保留 loopback 身份 |
| 其他／缺參數／解析失败 | HTTP 400；不是 404。W0 實際驗證此邊界 |
| WebSocket `/danmaku-websocket` | NIO shouldUpgrade 不限制 path；W0 僅證明 101／關閉握手，不證明彈幕資料或 Origin 安全 |
| `iinaDM://`、`iinaWebDM://` | DanmakuSessionManager 分外掛／web 路徑，payload 含版本或 hex(id＋分隔符＋url)；保留 DanamkuMethod 方法字串、設定同步與 sessionEnded 釋放 |
| `iina://open`／`iina://iina-plus.base64`、`plusplayer://` | 外部播放器／WKURLSchemeHandler 協議；UI 重構不得單方改名 |

W10 刪除前必查：Main／JSPlayer／OpenFiles／legacy Preferences storyboards、選集 xib、Assets 字串載入、Localizable／mul.lproj、empty.m4a、test.htm、douyin.js／douyin.html／huya.js、WebFiles 的 CCL／mpegts.js／flvplayer 資源、外掛包及 Info.json 契約、Block-List XML、Core Data 三個模型版本、PreferenceKeys、通知名與 bookmark.Row。legacy Preferences 被打包但沒有現行載入入口；本包不刪任何資源。

## 4. 資料盤點、隔離及還原

### 4.1 真實落點與樣本

| 資料 | 當前落點／責任 | W0 處理 |
| --- | --- | --- |
| 書籤 | `~/Library/Application Support/IINA+/DataModel.sqlite`＋WAL／SHM；NSPersistentContainer 預設依**程式名稱**，不是 Bundle ID | 1 筆真實資料；備份及 Core Data 重讀；不輸出 URL／remark |
| 模型 | current=`Bookmark v0.3`；仍含原版／v0.2 | cover、liveName、liveTitle、order(Double)、remark、state(Int16)、updateDate、url；保持 metadata／主鍵及順序 |
| 偏好 | `~/Library/Preferences/com.xjbeta.iina-plus.plist`；Preferences／@AppStorage | 15 個鍵；完整 plist 副本及反序列化相等，值不發布 |
| 站點憑證 | HTTPStorages／WebKit 的 com.xjbeta.iina-plus 資料；shared Cookie、無多帳號隔離 | 私人副本保存，不將真實 cookies 載入測試 App；無 Keychain 帳號池 |
| 日誌／網站資源 | Application Support/com.xjbeta.iina-plus | 私人備份；WebFiles 啟動時會重建，原使用者目錄未被測試 App 觸碰 |
| 可重建快取 | Caches/com.xjbeta.iina-plus、Caches/com.hackemist.SDImageCache | 一併備份，不執行清理 |
| Saved State／獨立 binarycookies | 該識別的 savedState／binarycookies 本機未找到 | 明確記錄缺席，不用空檔冒充備份 |

私人備份：`~/Library/Application Support/IINA-ANI-W0-Backups/2026-10-07.6cyfunae/`，目錄權限 700，包含 `raw/`、`DataModel.backup.sqlite`、`restored/`、`original-hashes.json`。它在工程與 `.build` 之外，不會隨 DerivedData 清理遺失。**含私人資料及憑證；不要提交或對外分享。**

### 4.2 已實際執行的還原驗證

1. 啟動前確認無 IINA+／上游 fork 行程，19080 無 listener；既有 IINA 播放器行程保持不動。
2. 複製 551 個檔案，複製前後逐檔 SHA-256 相等。SQLite 操作只作用於副本，避免讀寫真實 WAL／SHM。
3. 由副本的 SQLite backup API 產生獨立、完整 `DataModel.backup.sqlite`，而非只拷貝可能缺 WAL 的 .sqlite。
4. 還原到另一個 `restored/Library/Application Support/IINA+/DataModel.sqlite`；integrity_check=ok；所有資料表的值、主鍵、metadata 與備份前邏輯內容相等；偏好 plist 解碼結果相等。
5. 使用本次建置的 DataModel.momd 實際 Core Data 載入還原庫：1 筆書籤、order=[1.0]，不只靠 SQL 可讀判定。
6. 測試 App 使用 `CFFIXED_USER_HOME=.build/w0/home`＋獨立 Bundle ID。日誌及 lsof 確認 Core Data／SDImageCache 在隔離 home；只改 Bundle ID 並不足以隔離 IINA+ 名稱的資料庫。
7. 另建立公開的普通影片、直播、劇集三筆 UI 樣本，order=[0,1,2]；重啟 App 後實際呈現三筆，結束後再次 Core Data 重讀仍為三筆同順序。此樣本不是使用者收藏副本，也不聲稱舊版本遷移已完成。
8. 執行後原 profile 551 檔 SHA-256 全部未變。私人永久備份 integrity_check=ok。測試 App 正常退出（exit 0），本機 listener 已釋放；未停止使用者 IINA。

還原操作：先停止使用同一 store 的 App，再從私人備份複製到**另一個隔離 home**；以 `DataModel.backup.sqlite` 作主庫，不混入其他時點的 WAL／SHM；偏好及站點資料分別從 raw 對應目錄還原。先驗 integrity_check／Core Data／排序，再由 W5 定義真實使用者資料切換。**本次沒有覆寫真實 Library，也沒有完成 W5 schema 遷移。**

## 5. 實際運行與舊 UI 證據

建置命令：

```sh
xcodebuild -project 'IINA+.xcodeproj' -scheme 'IINA+' \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

API 樣例（只含公開頁面，沒有簽名串流）：

```sh
curl --get --data-urlencode 'url=https://www.dongmandaquan.vip/vodplay/1-1-2.html' \
  http://127.0.0.1:19080/video
```

此命令用於運行中的隔離 App；完整回應可能含短效媒體地址，不能直接放進共享日誌。實測以臨時 Python／Swift 程式驅動 SQLite／Core Data、AppKit Accessibility、HTTP、WebSocket 及 ffprobe／ffmpeg；程式已於結案移除，保留以下結果與產物，不新增永久 debug 入口或網站依賴測試。

| 場景／樣本 | 本次結果 | 證據 |
| --- | --- | --- |
| 建置及現有 App 啟動 | BUILD SUCCEEDED；真實 AppKit 主視窗；不是舊工程或 Animeko | `.build/w0/evidence/build.log` |
| 原資料備份／還原 | 551 檔、1 書籤、15 偏好鍵；完整恢復、Core Data 重讀、原 profile 未變 | snapshot.json、verification.json |
| Fengche 非首集 | `/vodplay/1-1-2.html` HTTP 200，標題含第02集，線路可解析 | smoke.json |
| Fengche 媒體 | 备用③ (1)：ffprobe H.264／AAC，FFmpeg 一秒解碼 exit 0；线路② (2)：probe exit 1、decode exit 187；沒有重跑失敗線或宣稱根因 | smoke.json／smoke-output.txt |
| girigiri | `/GV27206/` HTTP 200，青之箱 第二季 - 01，简中 (1)；主 UI 顯示該結果列 | smoke.json／search-result.png |
| B 站普通影片 | `/video/BV1xx411c7mD` HTTP 200，字幕君交流场所，360P／480P 候選 | smoke.json；不代表媒體播放通過 |
| B 站直播 | `live.bilibili.com/6` HTTP 200，高清／超清候選 | smoke.json；不代表直播／彈幕播放通過 |
| 無支援 URL、缺 url、未知 route | 各 HTTP 400；POST iinaurl 缺參數亦 400 | 對應 *.body；空 body 是現行錯誤契約 |
| `/video.mp4`、`/danmaku/test.htm` | 各 HTTP 200；前者為 placeholder 非影片，後者可讀 | video-placeholder.m4a、danmaku-test.htm |
| WebSocket | upgrade=101，送正常 close frame；未發 iinaDM session | verification.json |
| 書籤列表、設定、File Open、搜尋 | 操作實際選單／側欄／文字欄／設定 toolbar；不是靜態設計稿 | 下方 PNG 清單 |
| Fengche 選集既存缺口 | 線路可顯示，但葉節點標題空白；實際選取後網址欄變空、結果清空 | fengche-select-baseline.png／fengche-empty-selection.png／ui-observations.json |

本機去敏截圖均位於 `.build/w0/evidence/`：

- `main-bookmarks.png`：500×650 pt 舊主視窗，三種公開書籤。
- `search-result.png`：網址輸入及真實 girigiri 結果。
- `fengche-select-baseline.png`、`fengche-empty-selection.png`：重構前選集失效證據。
- `open-files.png`：File → Open 的影片／XML 入口。
- `settings-general.png`、`settings-sites.png`、`settings-advanced.png`、`settings-about.png`：現有四個設定 pane。

截圖與執行產物留在被忽略的 `.build`，不納入 App 資源；去敏 evidence 亦另存到上述工程外私人備份的 `evidence/`，清理 `.build` 不會丟失本次基線。若分享僅取去敏 evidence，不分享 raw／restored。App log、完整 API JSON、全螢幕權限探測圖及含系統 Recent Items 的原始 AX dump 不作公開證據，結案清除；AX 觀察摘要另存 ui-observations.json。

## 6. 歷史失效、W0 既存缺口及未驗證範圍

| 分類 | 事實／風險 | 交接位置 |
| --- | --- | --- |
| 歷史失效 | senfun YHZY 分段偽裝副檔名被 FFmpeg 拒；另一集 wjzy2 主機無回應 | W3 按能力／失效原因處理，不刪整個來源 |
| 歷史失效 | yinghua 六條線中兩條 TLS EOF；成功線亦曾退出逾時 | W3 保留線路身份及真實失效原因 |
| 歷史不支援 | didahd 其他加密線／網盤；热播之家 encrypt=3 無可驗證外部媒体，未接入 | 不當成回歸或補假 fallback |
| W0 基線媒體失敗 | Fengche 第2集线路②解析有地址，但本次 probe／decode 失敗 | 已在 App 原始碼未變時發現；不是 W0 造成的回歸；根因未判定 |
| W0 基線 UI 缺口 | dilidili／youknow／fqdm／wedm／forest／fengche 不在 SelectVideoViewController 的 displayString／selection switch；Fengche 已在真實 UI 證明空葉標題及空 URL | W1／W3 全 caller 遷移，W9 使用同一選擇契約；W0 不擅自修補 |
| 靜態既存風險 | IINA plugin 已快取時 open(result:) 的有效 guard 後只剩註解；mpv 也受主 UI 外掛檢查擋住 | W1 播放協調及取消；需真實播放器狀態轉移驗證 |
| 靜態既存缺口 | cc163 無彈幕；qieTV 在 JSPlayer 不啟 startDM；Douyu 主題頁 getDouyuHtml 回空 roomIds／pageId；DASH 註冊關閉 | W3 明示來源能力；不以重構聲稱補完 |
| 靜態既存風險 | DouYinDM 查 douyin.html 的 DouYin subdirectory，而打包資源在根；未執行該彈幕路徑 | W3／W10 查資源載入與實際直播 |
| 靜態既存架構 | HTTP 直接 decoder、UI 手動 episodeList 分派；Cookie 共用；無作品收藏、Bangumi、號池、下載服務 | W1–W7 的實作範圍，不把盤點冒充服務完成 |
| 既存建置警告 | Preferences.storyboard 無入口，但仍在 Resources | W10 核對全部引用後清理；本次保留 |

**未驗證**：外部 IINA／mpv 視窗載入、JSPlayer 真實直播、站點登入／憑證失效與多帳號、彈幕載入／取消／重連／多視窗／釋放、虎牙及嘀嗒代理本次實際拉流、所有來源／作品／線路、舊版模型→新收藏的 W5 遷移、macOS 13.5 真機及正式發佈。mpv 本機 PATH 無可執行檔；既有 IINA 行程未被本次接管。這些不是 W0 完成門檻，不能據本包對外宣稱全部功能正常。

## 7. W0 門檻結論

| 門檻 | 結果 |
| --- | --- |
| 來源／播放器能力矩陣 | 全部 27 case；程式能力與歷史／本次實測分列 |
| 選單、URL、HTTP、書籤入口有服務遷移位置 | §3 逐入口及協議清單；不存在的 URL handler／匯出能力明確標記 |
| 隔離資料可還原 | 真實資料完整副本、SQLite／Core Data 邏輯重讀、偏好相等、551 原檔未變；工程外私人備份已保存 |
| 舊 UI 與歷史失效／回歸基線 | 真實視窗 PNG／AX／API／媒體結果；既存缺口沒有隱藏或誤標為本包回歸 |

W0 結案；W1–W10 仍未開始。W0 盤點 session 未修改 App；後續既存功能修復另記於 §8。

## 8. W0 留檔缺口修復（2026-10-07）

本節是 W0 之後的修復紀錄；§1–§7 保留當時的基線事實，不代表修復後狀態。範圍是既有入口與解析契約，沒有開始 W1–W10、新 UI、收藏遷移或新服務。

### 8.1 修復與更正

| 項目 | 現在狀態與改動 | 執行證據／邊界 |
| --- | --- | --- |
| 六站選集 | SelectVideoViewController 補上 dilidili／youknow／fqdm／wedm／forest／fengche 的葉標題與 item.url 分派 | 六站均在真實 App 選中非首個葉節點，回寫正確非空網址並取得實際線路／品質列表 |
| Fqdm 目錄 | 另發現現行頁面已改用 module-play-list；修正舊 play-tab-list selector | detail 129 修復前無選集；修復後選中 nid/2（第0001集，首項為特別篇）並取得五條線路 |
| 外部播放器入口 | 主 UI 僅在播放器為 IINA 時檢查 IINA 外掛；open(result:) 清除重複 guard／廢棄註解，統一執行既有 openWithPlayer | 保留使用者在 W0 後已補回的啟播呼叫；無 IINA 外掛的隔離 App 以 mpv 選項取得结果並真實啟播，未接管使用者 IINA |
| QieTV 彈幕 | JSPlayer 將 qieTV 納入既有 startDM 分派 | WKWebView 實際顯示公開直播留言；兩窗並存、關窗與重開均已操作；不是影片播放驗收 |
| Douyu 主題頁 | 從現行頁面解析 room_ids／zhtId／zhtName；沿用原方法傳入 pageId，記錄對應 topicName；依站方契約改用 pageData1 查子房間 | PUBGYLSJS 真實 UI 顯示 30 個有名稱子房間，選第二個後取得 /5818871 原畫品質；無相應 switch-room 元件的頁面沿用既有單房回退 |
| Douyu 內嵌 JSON | 按 JS 字串跳脫與 JSON 字串邊界掃描，避免字串內括號截斷及 UTF-16／Character 索引混用 | 實際 App 模組通過 Unicode 跳脫、內嵌 JSON 字串／括號、多位元字首、無元件等離線樣本；公開一般房間解析亦通過 |
| B 站 normal IINA URL | YouGetJSON.videoUrl(forDash:) 在沒有 dashUrl 時使用既有 direct URL，保留獨立音軌選項；未啟用 MPD 註冊 | /video/iinaurl normal 實際 HTTP 200；App 模組驗證直連、音軌、既存 dashUrl 優先及缺失品質 nil |
| HTTP b23 入口 | HTTPHandler.decode 重用既有 bilibiliUrlFormatter，再 decode／prepareVideoUrl；不把獨立 HTTP 請求改成 UI 的共用取消 Task | 公開 b23.tv/BV1xx411c7mD 轉址觀察及 /video、/video/iinaurl normal 均 200；無支援網址及缺 url 仍 400 |
| JSPlayer 能力 | supportWebPlayer 改為只允許六個已接入直播來源，其他來源不再誤入 Web 播放器 | App 模組驗證六個允許來源與 unsupported 拒絕；不宣稱 cc163 具有彈幕 |
| DouYin 資源風險 | 更正 W0 靜態判定：工程的 Copy DouYin 相位另有複製到 Resources/DouYin/douyin.html，並非只有根目錄資源；無需改碼 | 最終 App bundle 的既有 Bundle 資源查找實際成功；未驗證抖音直播 WebSocket |
| Preferences 警告 | 開始修復時使用者已設定舊 storyboard initialViewController；本次保留，不刪舊資源或控制器 | 最終建置沒有原先 Preferences 無入口警告；其他既存警告未一併處理 |

### 8.2 已定位但不能當成程式修復的媒體失敗

以下是本次取樣時的遠端狀態，不是所有作品／線路永久失效；沒有加入重試、偽代理、換站或假 fallback。

- Fengche 第2集线路②：實際解析器與站方 player_aaaa 取址一致；媒體指向 cdn.wlcdn99.com:777。Google／Cloudflare DoH 的相關 CDN 域名查詢為 NOERROR 但無 A／AAAA，連線 TLS 零位元組 EOF；此執行環境另限制 777 埠。保留原線路及失效證據；不是補 Referer 可以修復的選集錯誤。
- Senfun YHZY：失敗 manifest 的 787／788 個 .jpeg 分段指向 v6.ttuv77.com（NXDOMAIN），且 FFmpeg 另有副檔名限制；另一個以 .ts 分段的 YHZY 樣本 H.264／AAC 解碼成功。wjzy2 的 top.cctvm3u8.com 為 NXDOMAIN，其他主機樣本可解碼；不刪整個來源。
- Yinghua 舊 TLS EOF 樣本：hd.ijycnd.com 為 NXDOMAIN，vodcnd0*.trjho.com 無 A；其他取样線路仍有 manifest／解碼成功。另觀察到跳轉至當前未辨識的 yinghuabb.com，未在本次舊缺口修復中擴增網域接入。
- cc163 彈幕、MPD HTTP 註冊、didahd 其他加密線／網盤、热播之家 encrypt=3 與規劃中的新服務仍是未實作／未支援能力，沒有用本次修復冒充完成。

### 8.3 最終驗證與隔離

- 最終 Debug arm64 無正式簽署 xcodebuild 成功。測試副本為 org.iina-ani.gap-repair，以 CFFIXED_USER_HOME 隔離 App Support／Core Data／快取；CFPreferences 使用獨立測試 domain，HTTP 為 19180，未接管使用者的 19080 或既有 IINA／IINA+。
- 真實主介面雙擊 Fengche 品質列，經既有 Processes／customMpvPath 啟動臨時 libmpv runner：file-loaded、time-pos=2.021、1920×804、停止並銷毀成功。runner 連結已安裝 IINA 的真實 libmpv，沒有模擬媒體回應；本機沒有可用官方 mpv CLI，這不等於外部 IINA／mpv 視窗驗收。
- QieTV 關窗以實際 windowWillClose 斷點逐步觀察：socket 為 nil、controller.danmaku 為 nil、webView 為 nil，另一視窗仍有獨立 danmaku；移除斷點後再次關閉、重開並正常退出。QieTV FLV 在本環境回 403，Web 影片 decodedFrames=0；沒有把收到彈幕或 Loading 截圖當作播放成功。未驗證強制斷線重連或 heartbeat Task 的取消狀態。
- 臨時 runner、AX／模型 smoke 腳本、fixture server、測試 App／home／偏好與含簽名 URL 的回應已清除；19180／19181 已釋放。去敏結果、原生 UI PNG／AX、最終建置及遠端診斷保留於 .build/gap-repair/evidence/，另存工程外私人備份 ~/Library/Application Support/IINA-ANI-W0-Backups/2026-10-07.6cyfunae/gap-repair-evidence/，不包含 App log、完整媒體 JSON 或 IINA scheme。
- 本工程沒有既有單元測試 target；使用實際 App、實際 App 模組及短期 fixture smoke 驗證，未留下只檢查 source text／轉發接線的永久測試。外部播放器視窗、抖音實際彈幕、完整來源／線路、登入／多帳號、macOS 13.5 及正式發佈仍未驗證。
