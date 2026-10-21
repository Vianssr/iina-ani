# IINA-ANI：IINA+ 重構 fork

> 本文維護 fork 定位、架構與資料／發佈安全約束。專案入口見 [README](../../README.md)，功能操作見 [使用指南](../USER_GUIDE.md)，工作包狀態、產品契約與未簽收關卡統一見 [前端重構規劃](../plans/FRONTEND_REFACTOR_PLAN.md#plan-status)，逐次交付證據見 [工作記錄](../history/WORK_LOG.md)。規劃與實作交付不等於驗收通過。

## 1. 專案定位

IINA-ANI 是 [xjbeta/iina-plus](https://github.com/xjbeta/iina-plus) 的非官方重構 fork，以既有站點解析、播放器整合及彈幕能力為起點，在維持可觀察行為的前提下改善結構與可維護性。

- 沿用現有 Swift 主程式、Core Data 與 WebKit 整合。
- 沿用外部 IINA／mpv 播放路徑、IINA 彈幕外掛協議及內建 JSPlayer 路徑。
- 保留 HuyaKit 本地 Swift Package 與 `huyaproxy` CLI 邊界。
- 不以全面替換儲存引擎或重造播放器為前提。
- 專案正式名稱為 **IINA-ANI**；文件中的本專案名稱統一使用 `IINA-ANI`。IINA+ 僅用於上游名稱、既有技術識別及歷史記錄。原始碼目錄為 `IINA-ANI/`，工程為 `IINA-ANI.xcodeproj`，target／scheme、App 顯示名稱與產物已更名為 `IINA-ANI`；Bundle ID `com.xjbeta.iina-plus` 與既有資料目錄刻意保留，工程品牌更名不代表獨立發佈。
- 本專案與 IINA、IINA+、Animeko 無官方隸屬關係。

### 原有追番方向的處理

現行產品重點為一站式追番：瀏覽搜尋、Bangumi 基礎資訊、日常更新、作品／連結收藏、集數與來源選擇、播放、下載及可自訂前端；契約見 [FRONTEND_REFACTOR_PLAN.md](../plans/FRONTEND_REFACTOR_PLAN.md)。後續加入的網站原為測試，定位為可替換背景來源，不以逐站支援、全部清單可用或網站號池為目標。css1 訂閱透過受控轉換／差異預覽／明確套用更新既有來源的公開搜尋規則，不導入帳號、憑證或遠端播放程式；不改原專案帳號能力。W9 已整合頁面及真實服務命令，不能把 UI 交付當成原 M2 帳號下載或集中產品驗收通過。網站下載沿用既有解析器的能力邊界，訂閱更新不擴大下載宣稱。組件自由編排、非基礎能力可選、受限 Layout 腳本與可分享 .iinaskin 沿用既有契約；osu-framework／osu 僅借鑑方法，不引入 framework 或 .osk 匯入，固定來源與取捨見重構文檔附錄 B。

後加番劇搜尋／自動尋源統一由 css1 訂閱啟用：設定中檢查、預覽並明確套用後才宣告該來源搜尋能力，沒有測試模式開關或舊搜尋規則 fallback。`Sources/native-search.json` 與 `Sources/fqdm.json` 保留為轉換基線；實際搜尋使用訂閱的 searchUrl，核准重新導向後以回應網址建立作品／集數候選，不以基線網域覆寫訂閱鏈接。原專案來源、直接網址解析及既有播放／目錄適配器保留。更新失敗／缺項保留先前已套用配置，未套用者不啟用；不自動遷移或刪除隔離測試使用者資料。

目前日常推薦源為 Bangumi：右上角日曆按鈕開啟全週放送（官方 calendar API），採七欄網格。發現頁依序為 Trends → 繼續觀看 → 推薦；Trends 210 pt，封面填滿與卡片間距縮減，推薦增加自適應有效欄數。續看是獨立 playback.continue 組件，一行橫向展示作品／集數、實際播放秒數及進度，無資料收為緊湊提示；通知驅動更新。播放歷史 owner 是 AppServices.playbackHistory()，獨立保存在 Playback/history-v1.json，不屬快取／分享佈局；只存原選擇身份與實際觀察秒數，不存短效串流或憑證。resumePlayback 重新解析來源再定位，不以開URL成功當作實播。Bangumi 推薦按 anime/browser/?sort=trends&page=N 延續熱度順序與去重，排期／熱度仍不代表可播放。收藏更新在收藏頁，原作品／連結雙欄保留；全部斷點仍符合舊三／四區或兩區內建形狀者才遷移，自訂 Layout 不覆寫。

主頁三區共用同一個縱向交互容器，Trends／續看不固定在頂部；推薦網格直接納入共同文件，橫向卡片保留各自的左右捲動。編排及 Skin 的原組件身份不變，自訂頁面的獨立推薦組件仍使用原本的面板捲動。

推薦網格使用 WorkspaceFeedGridLayout，欄數、卡寬與水平座標只依 collection 自身寬度計算並快取；不使用外層 clip 寬度重新分配欄間距。捲動、資料刷新及載入更多保持既有欄位座標，只更新內容高度；真正改變可用寬度才重新計算。手動切換組件密度會重建 layout，立即套用新密度；零寬度的切頁暫態不覆寫快取。
推薦網格只在整列換行邊界保留右側 15 pt，可用寬度一次扣除，不逐卡片增加內距；卡片最小間距仍為 4 pt，取整餘量按固定欄位分配。面板原邊距及 Trends／繼續觀看不變。
推薦載入／錯誤／末頁提示位於網格下方，頁尾保留至少 32 pt；一般載入提示顯示或收起不再改變網格起點。主頁共同捲動與自訂獨立面板切換時，內容維持在頁尾之前。

`IINA-ANI/Workspace/` 現為唯一主 UI，提供十三種組件、草稿編排、Skin 管理及五組設定；W10 補回 Bilibili 關注動態及直播收藏操作。Layout／Skin／私有呈現狀態独立於作品、來源、下載與播放器 owner。固定選單在作者佈局刪除入口後仍可開啟恢復頁，不覆寫原 Layout。移除面板只取消其查詢，不刪收藏、播放歷史或停止已提交任務。Layout 原子保存於 `Workspace/layout-v1.json`，Skin 保存於 `Skins/`，純換皮不換 Layout。舊主視窗／側欄／AppKit 與 SwiftUI 設定頁已移除；JSPlayer、影片＋XML 開啟、登入容器與外掛安裝保留。格式見 [Skin 範例](../../Examples/Skins/README.md)。

Torrent 固定採用 **libtorrent-rasterbar 2.1.2**。W11.1–W11.3／MT1／MT2 已完成 arm64／x86_64 靜態核心、Swift／C ABI 所有權、metadata／精確選檔、DownloadService 共享與持久恢復、NIO Range／IINA／mpv 串流。既有限速 peer 的 600 秒影片、未下載 300 秒／570 秒 seek、精確 bytes、雙 reader／取消隔離及停止撤銷證據見[附錄 A.8–A.10](../plans/FRONTEND_REFACTOR_PLAN.md#a-w111)。OpenSSL 3.5.8、隨包 CA／HTTPS tracker 驗證、上傳同意／限速及 private tracker 安全政策維持 §4.8／§5.4 契約；W11.4 UI 狀態見下，不把過去核心實播當成新產品入口驗收。

W11.4 的匯入／精確檔案選取／上傳同意、設定活動限速／停止 P2P 與共享下載頁已隨 W9 實作。BT 現整合在作品的「來源與播放選擇」窗口；全域 magnet／本機種子入口同路由，既有 torrent.import 仍可自訂編排。TorrentSearchService 每次讀取 bt1.json 的 RSS searchUrl，只查詢公開 metadata；結果與影片檔案均明選，上傳同意後才啟動 P2P。2026-10-13 已走正式 AppDelegate／Workspace，驗證作品帶入、640／460 寬窗口、自製非首檔影片 loopback magnet→metadata→mpv 實播及停止；公開 RSS 的 HTTP 403 如實呈現，不繞過站方限制。MT3 全矩陣不因此簽收。

詳情另提供「快速下載」獨立窗口，區分在線源下載與 BT下載：在線先明選作品來源，再列出該來源精確集數供勾選，解析品質／線路後批次提交；換來源清除未提交選擇與解析。BT metadata 以影片核取方塊一次提交多檔，仍保留原本單列播放選擇。兩者共用 DownloadService；窗口只擁有查詢、解析與未提交工作，不擁有已建立的傳輸。部分失敗保留未提交項目，本次窗口內的成功項目不重複提交，不新增來源／帳號能力。

2026-10-14 修正公開磁力 session 的 tracker tier 排程：同時聯絡磁力連結既有 tiers，避免失效前置 tracker 耗盡 metadata 等待期限；不增加 tracker、不延長逾時、不改本機種子匯入。相同公開搜尋資源在修正前 60 秒沒有 peer，修正後 App-linked 核心取得 29 檔 metadata；正式 App 的搜尋→選取→匯入也顯示 29 檔且未預選或自動下載。另一筆合集仍無可用 peer，故不宣稱全部搜尋結果可用。

目前沒有自建 TypeScript IINA 插件的原始碼或建置入口。既有彈幕外掛由 `InstallDeps.sh` 自另一個倉庫下載；`WebFiles/package.json` 僅管理 App 內的網頁資源依賴。

## 2. 上游基線與目前交付

### 2.1 原始碼來源

- 上游：<https://github.com/xjbeta/iina-plus>
- 基線提交：[`4fbbe9131b8fc6500fea7ecc3e9cea2834910074`](https://github.com/xjbeta/iina-plus/commit/4fbbe9131b8fc6500fea7ecc3e9cea2834910074)，提交日期 2026-09-22。
- 初次匯入時，`IINA+/` 的 167 個檔案、`IINA+.xcodeproj/` 的 4 個檔案、`HuyaKit/` 的 11 個檔案，均與該基線逐檔雜湊一致；不計 Finder `.DS_Store`。此為匯入歷史，不代表目前重構後的檔案仍相同。
- 本機最初為沒有 `.git` 的原始碼快照；2026-10-21 依維護者要求初始化 Git，原始碼倉庫為 [Vianssr/iina-ani](https://github.com/Vianssr/iina-ani)，預設分支為 `main`。本機助理指令與私有配置不納入倉庫。

### 2.2 初次匯入整理（歷史）

- 移除舊 `IINA-ANI-dsixzwstckaysndufqdncoiirnlj/` 衍生資料。
- 移除根目錄的 `CompilationCache.noindex/`、`ModuleCache.noindex/`、`SymbolCache.noindex/`。
- 移除 Finder `.DS_Store`，加入忽略規則，避免重新納入快取、個人 Xcode 設定及下載依賴。
- 新增 README，重寫本文件、代理規範與問題回報模板，並標明架構分析屬於上游基線。
- 保留全部 App／HuyaKit 原始碼、工程資源、依賴鎖檔及授權文件；不以檔名判斷舊 UI、JavaScript 或媒體資源無用而刪除。

**本節僅記錄初次匯入整理，不代表目前交付狀態；後續重構與驗證見工作記錄及重構規劃。**

## 3. 目錄與現有能力

| 路徑 | 現有職責 |
| --- | --- |
| `IINA-ANI/App/` | AppDelegate 啟動／關閉、AppServices 組裝根、Preferences 與 MainMenu |
| `IINA-ANI/Features/Accounts/` | 站點帳號、OAuth、Cookies 管理與登入 UI |
| `IINA-ANI/Features/Bangumi/` | Bangumi 模型、查詢及作品同步 |
| `IINA-ANI/Features/Discovery/` | 搜尋、日常聚合及 Bilibili 動態 |
| `IINA-ANI/Features/Sources/` | registry、來源配置／訂閱／選擇、媒體結果；`Decoders/` 放站點解析器 |
| `IINA-ANI/Features/Playback/` | 播放協調、參數編碼、進度／歷史；子目錄 `Danmaku/`、`JSPlayer/`、`OpenFiles/` 保留各自協議與 UI |
| `IINA-ANI/Features/Downloads/` | 共享下載 owner、直連／HLS 後端、任務模型與來源解析 |
| `IINA-ANI/Features/Torrent/` | native session、metadata 搜尋、下載後端、HTTP Range 與串流播放 |
| `IINA-ANI/Infrastructure/Persistence/` | Work／Favorite／Bookmark 儲存、遷移與 AppStoragePaths；不改既有磁碟資料位置 |
| `IINA-ANI/Infrastructure/HTTP/`、`Cache/` | loopback HTTP／WebSocket／虎牙路由及圖片快取；兩者同屬 Infrastructure |
| `IINA-ANI/Shared/` | extensions、日誌、識別常數、限流與計時工具 |
| `IINA-ANI/Workspace/Shell/` | 主視窗、renderer 及會話呈現狀態 |
| `IINA-ANI/Workspace/Panels/`、`Settings/` | 產品面板與設定 UI；兩者同屬 Workspace |
| `IINA-ANI/Workspace/Layout/`、`Skin/` | Layout 模型／能力／registry／交易／保存／編排／腳本與 Skin 驗證／封存／保存／管理；兩者同屬 Workspace |
| `IINA-ANI/Core Data/`、`Assets/`、`Sources/`、`WebFiles/` | 保留版本化 schema、圖像、來源 JSON 與網頁資源位置；皆位於 IINA-ANI |
| `HuyaKit/`、`Native/` | 獨立虎牙套件、Torrent 原生邊界及 LayoutScript helper |
| `Tests/` | 按功能分類的回歸來源；根層 `run-*.sh` 是穩定執行入口，Fixtures 保留獨立 |
| `IINA-ANI.xcodeproj/` | 唯一 App 工程入口，Xcode groups 與實體功能目錄對應 |
| `docs/` | USER_GUIDE、architecture、plans、research、history；歷史驗證與當前能力分開維護 |

這次目錄切分是同一 `IINA_ANI` module 內的責任分類，不新增 target 或套件，也不改 public symbols、Storyboard 名稱、Core Data 版本、Bundle ID、偏好鍵或外掛 wire format。共用資源保留原有位置，避免把原始碼搬移變成資料遷移。

新增程式優先放入對應功能：業務服務放 Features，儲存／傳輸機制放 Infrastructure，主視窗呈現放 Workspace，真正跨功能且不擁有業務狀態的小工具才放 Shared。AppServices 維持唯一組裝根；不要重新建立 `Utils` 雜項集合。

現有主要資料流：

```text
網址／書籤／Bilibili 動態
  → Workspace 搜尋／收藏／詳情組件
  → VideoDecoder＋站點 actor
  → YouGetJSON／Stream
  → 選品質／準備 URL 與彈幕檔
  → Processes → IINA／mpv

直播彈幕 → DanmakuEvent
  ├─ 本機 WebSocket → IINA 彈幕外掛
  └─ JavaScript bridge → 內建 JSPlayer

虎牙 .slice → HuyaKit → 本機 FLV 代理 → 播放器
```

上游基線與 fork 現行能力須分開描述，不把後續重構回寫成上游原有能力。

## 4. 重構目標與約束

以下约束持續適用。2026-10-10 的依賴整理不等於整體產品驗收；當前驗證政策及正式 App 驗收要求以 [重構規劃 §0.2](../plans/FRONTEND_REFACTOR_PLAN.md#plan-status) 為準。

### 4.1 播放流程

網址輸入、選集／品質及捕獲的帳號上下文由 Workspace 詳情持有畫面狀態，經共同 VideoDecoder／Processes 啟播；直播／影片來源窗口只顯示登入狀態，不提供帳號切換。帳號登入／登出集中於設定，css1 訂閱檢查／預覽／套用位於其獨立子窗口。舊 MainViewController 及重複逐站選集分派已移除。HTTP、JSPlayer 與本機影片＋XML 仍沿用各自既有協議與服務，不另建解析或播放 owner.

驗收必須涵蓋取消、錯誤與播放器載入結果；「成功呼叫 URL scheme」不等於播放成功。

### 4.2 站點與資料契約

`YouGetJSON` 已與 `PlaybackEncoder` 分離，HTTP／播放呼叫端已遷移，保留原有外掛 wire format。`VideoDecoder`、下載解析與 Discovery 共用明確注入的來源上下文；不為每個 concrete type 增加 protocol。後續仍須保持站點原始回應、統一媒體結果與播放器參數的界線。

站點擴充沿用已存在的 `SupportSiteProtocol` 與適配器模式；沒有實際需求前不引入動態插件框架。

### 4.3 彈幕與資源生命週期

保留直播事件與點播 XML 的區別。明確規定播放視窗、工作階段、上游 WebSocket、本機訂閱及取消任務的擁有者；用實際關閉、重連、多視窗場景驗證，不把 actor 隔離當作生命週期管理已完成。

### 4.4 資料與設定

保留 Core Data 書籤與現有 UserDefaults 行為。修改資料 schema、Bundle ID、Application Support 路徑或偏好鍵時，先定義遷移及備份策略，不丟失既有收藏或誤讀上游使用者資料。

### 4.5 不在本次範圍

- 刪減直播站點、移除內建播放器或取消舊播放器相容性。
- 替換 Core Data、另造 IINA 播放核心。
- 宣稱所有站點正常、所有上游外掛版本相容或最低系統已實測。

## 5. 建置與依賴

完整指令見 [README.md](../USER_GUIDE.md#建置)。

- App target 的 deployment target 是 macOS 13.5，不以 project 層殘留的 10.15 設定作為最低系統承諾。
- App Swift language mode 是 6.0；HuyaKit 要求 Swift tools 6.4。
- 工程透過 Swift Package Manager 引入 Swift 依賴；保留 App 與 HuyaKit 的 `Package.resolved`。
- `InstallDeps.sh` 使用 `gh` 下載外部 `iina-plugin-danmaku.iinaplgz`，再於 `WebFiles/` 執行 `npm install`。
- 不帶參數會取外掛最新 release；可用第一個參數指定真實 tag。發佈必須記錄外掛版本，不把固定 App commit 誤認為固定全部外部資源。
- `CI=true` 會讓腳本從外掛 metadata 更新 `IINAApp.swift` 的版本常數；依賴安裝後須明確記錄這類來源變動。
- 編譯產物使用 `.build/xcode` 或外部 DerivedData，不放回原始碼目錄。
- Bangumi OAuth 應用 ID／secret 由 `Config/App.xcconfig` 選擇性載入被忽略的 `Config/Local.xcconfig`，透過 Info.plist 注入；來源不帶真實憑證。缺失時登入／續期明確拒絕。這是 Git 衛生措施，非桌面端 secret 保密保證；使用者 token 仍只存 Keychain。
- W6 HLS 使用外部 FFmpeg 做本機 stream copy／MKV 封裝；直連檔不依賴它。helper 搜尋位置、缺少工具的明確錯誤、架構／最低系統／dylib 與 LGPL／GPL 打包要求見 README「真實下載服務與 FFmpeg」；目前未捆綁 Homebrew 二進位或宣稱發佈驗收。

## 6. fork 身分、安全與發佈邊界

工程與 App 品牌已更名為 IINA-ANI；目前刻意保留上游 Bundle ID 與既有資料目錄，避免更名造成資料遺失或協議變更，但這**不是正式 fork 發佈配置**：

| 項目 | 當前狀態 | 正式發佈前要求 |
| --- | --- | --- |
| 工程／App 名稱 | `IINA-ANI`；target／scheme／產物同名，Swift module 為 `IINA_ANI` | 保留合法上游歸屬；工程品牌更名不等於資料身分、簽署或發佈已配置 |
| Bundle ID | `com.xjbeta.iina-plus` | 配置 fork 自己的穩定 ID，定義資料遷移與共存策略 |
| 既有資料目錄 | 保留 Core Data 的 `Application Support/IINA+` 與既有偏好／資料佈局，避免遺失資料 | 獨立發佈前定義並驗證資料遷移與共存策略，不因 App 更名直接切換空目錄 |
| Sparkle feed／公鑰 | W10 已移除 Sparkle、feed／公鑰及檢查更新入口 | 尚無 fork 更新服务；若恢復，須使用自行管理的 feed／簽章，不能導向上游 |
| 簽署／公證 | 尚未配置 fork 發佈身分 | 使用自己的簽署及公證流程 |
| 本機服務 | `127.0.0.1`，預設 19080 | 驗證埠衝突、Origin／授權邊界及外掛相容性，不直接暴露到網路 |
| 外掛 | 上游外部發行包 | 固定並實測相容版本；修改協議需同步外掛端 |
| fork 倉庫／Issue／更新地址 | 尚未配置 | 使用真實維護地址，不把 fork 問題導向上游 |

開發驗證前應備份既有 IINA+ 資料，避免同時執行上游及 fork。自動更新已在 W10 程式及工程層移除；Bundle ID／Core Data／偏好路徑仍未分離，不把停用更新視為獨立發佈或資料共存驗收。

保留 [LICENSE](../../LICENSE) 的 GPL v3 及所有必要版權聲明，並保留 [LicenseForIcons.pdf](../../LicenseForIcons.pdf)。第三方套件、圖示及外掛分別遵守自己的授權。上游作者資訊不得改成 fork 作者來掩蓋來源；fork 維護資訊應另行追加。

## 7. 驗證方式與完成條件

| 改動 | 必要證據 |
| --- | --- |
| 文檔／目錄清理 | 檔案與工程引用一致、必要原始碼未被刪除、套件 manifest／工程格式有效 |
| 播放流程 | 真實網址完成解析、選品質／集數、IINA／mpv 載入，並驗證取消與失敗 |
| UI | 建置並啟動實際 `IINA-ANI.app`，互動及視窗截圖 |
| 彈幕 | 直播連線、點播 XML、速度／透明度設定與視窗關閉資源釋放 |
| 虎牙代理 | 實際拉流、指定品質與線路、播放器斷線後停止工作 |
| 儲存／資料遷移 | 舊書籤保留、排序不變、重啟後資料一致 |
| 發佈 | 獨立身分、簽署、公證、安裝、更新及與上游版本的資料邊界 |

目前 Xcode 工程及 HuyaKit 未配置自動化 test target。`Tests/run-work-library.sh` 以實際 Core Data 模型及生產型別運行 W1 的身份／映射／遷移回歸；Debug 建置後，`Tests/run-w5-favorites.sh` 運行 W5 收藏身份／獨立操作／刪除隔離及真實舊庫備份／版本化遷移／回滾／冷還原回歸。當前 model 為 Library v0.5，舊 model 保留供遷移；兩類收藏共享既有 Work／來源資料而不共用會員身份。備份與回退風險見 README。只為易回歸的可觀察行為保留測試，不用字串搜尋或 mock 回傳值代替功能驗證。

### 初次匯入整理的驗證邊界（歷史）

已完成的檢查：

- 匯入來源逐檔雜湊比對、Xcode／Swift 工具鏈版本與 HuyaKit manifest 解析。
- `project.pbxproj`、`Info.plist` 的 `plutil -lint` 及 `InstallDeps.sh` 的 shell 語法檢查。
- 136 個 Sources／Resources／Copy Files 建置引用檢查：缺少的僅為預期尚未下載的外掛包及 4 個 npm 資源，沒有因本次清理新增缺失。
- 10 個本地 Markdown 連結有效，程式碼區塊標記成對；舊衍生資料／快取已移除，授權與依賴鎖檔仍保留。
- 已清除 manifest 驗證產生的 `HuyaKit/.build/`。Finder 若重新產生 `.DS_Store`，由 `.gitignore` 排除。

沒有執行外部依賴安裝、完整 App 建置、App 啟動或站點播放；不得把套件 manifest 可解析或來源雜湊一致描述為完整建置通過。

## 8. 文檔維護

- `README.md`：新使用者入口、當前狀態及建置方法。
- `docs/USER_GUIDE.md`：完整功能操作、依賴、驗證入口與已知限制。
- `docs/architecture/PROJECT.md`：fork 範圍、架構演進與驗收約束。
- `docs/plans/FRONTEND_REFACTOR_PLAN.md`：下一階段前端設計、功能整合、工作拆解與完成門檻。
- `docs/plans/FRONTEND_W0_BASELINE.md`：W0 基線、能力矩陣與歷史驗證限制。
- 本機助理指令與設定不納入公開原始碼倉庫。
- `.github/ISSUE_TEMPLATE.md`：fork 問題回報格式，不自動提交任何外部 Issue。

每次改變架構或可觀察行為，同步更新對應文檔；明確區分已實現、已驗證與待實作。新增產品方向不得讓既有功能重構變成未經決定的全面改寫。
