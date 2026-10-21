# IINA-ANI 前端重構規劃

> 更新：2026-10-13。帳號 UI 已依使用者要求精簡，來源訂閱移入子窗口；W10 主入口切換與舊 UI 清理已實作；總驗收與既有未簽收門檻不因此通過。
> 正文是現行目標、契約、工作包與驗收要求；歷史交付集中於附錄 A，技術研究集中於附錄 B。規劃不代表功能已實作。

## 閱讀導覽

| 要查什麼 | 入口 |
| --- | --- |
| 現在完成到哪裡、目前可以驗證什麼 | [§0 現況與執行限制](#plan-status) |
| 必交需求與排除範圍 | [§1 目標與範圍](#plan-scope) |
| 現行架構、資料與服務邊界 | [§2 演進原則](#plan-evolution)、[§3 資料契約](#plan-contracts) |
| 基礎服務要滿足什麼行為 | [§4 基礎功能規格](#plan-services) |
| 工作順序、前置條件與完成門檻 | [§5 工作包與關卡](#plan-work) |
| 頁面、自由編排、Skin、腳本與設定體驗 | [§6 UI 設計](#plan-ui) |
| 實作約束與最終驗收 | [§7 工程原則](#plan-engineering)、[§8 驗收標準](#plan-acceptance) |
| 風險及尚待實作定案的事項 | [§9 風險與決策](#plan-risks) |
| 過去做過什麼、具體證據與失敗 | [附錄 A 歷史證據](#history) |
| 為何採用這些方法、上游來源 | [附錄 B 技術研究](#research) |

<a id="plan-status"></a>
## 0. 現況與執行限制

### 0.1 交付狀態摘要

| 範圍 | 狀態 | 尚未包含／未簽收 |
| --- | --- | --- |
| W0、W1、W3–W6 | 已驗收，詳見 §5.1／附錄 A | 不代表所有遠端來源、播放器或最低系統均通過 |
| W2 | 偏好、帳號及快取實作交付 | 完整真實雙帳號／失效後重新授權仍待簽收；使用者既有 Douyu、Bangumi 登入確認保留，不擴大採認 |
| W7 | 搜尋／日常服務、收藏及指定清單 guest 下載閉環已交付 | 原 M2 有效網站帳號下載等缺口仍保留，逐項對照見 [A.7](#a-w7) |
| W11.1–W11.3 | 已驗收，MT1／MT2 通過 | W11.4 UI 已隨 W9 整合；MT3／最低系統與正式包未簽收，不解除原 M2 |
| W8.1 | 工作區／組件實作交付，單元、Debug 編譯及隔離原生 host 煙霧通過 | 不是完整 W8／W9／M3 簽收；契約與證據見 [§5.3.1](#w81-contract) |
| W8.2 | Skin 包／資源實作交付，安全匯入匯出／回滾、素材邊界、原生外觀與 Debug 編譯通過 | 契約及局部證據見 [§5.3.2](#w82-contract)，不代替完整 W8／W9／M3 |
| W8.3 | 受限 JavaScript helper、Layout 生成／原生預覽／確認保存與撤銷已實作；Debug 編譯通過 | macOS 13.5／正式簽署與 App Sandbox 組合未驗證；外部腳本匯入關閉，不能全項簽收，見 [§5.3.3](#w83-contract) |
| W8.4 | 編輯／預覽／分享已實作交付；草稿交易、Skin 快照、作者重載、範例與格式文件 | 本機回歸與隔離原生操作見 [§5.3.4](#w84-contract)；不是 W9／M3 全產品簽收 |
| W9 | 頁面／真實命令整合已交付，見 [§5.3.5](#w9-contract) | 集中產品旅程、M3／MT3 與最低系統未簽收 |
| W10 | 切換實作已交付；總驗收受阻，見 [§5.3.6](#w10-contract) | §8 集中旅程、逐站、macOS 13.5／Intel、M2／M3／MT3 與正式發佈仍未簽收 |

### 0.2 目前驗證政策

**2026-10-11 已恢復正式 App 端到端驗收。** R0–R6 修復已完成，[R7 集中結果／受阻報告](#r7-acceptance)已交付；集中旅程失敗／缺環境逐項受阻，不提前簽收既有關卡。

原 M2／M3／MT3／M4 與 W8.3 安全門檻仍未因此通過。必須建置本份來源並走正式 AppDelegate／實際視窗；隔離 AppKit host 不能代替正式產品驗收。使用資料副本或隔離 profile 保護原資料，不清除既有帳號／收藏；P2P 仍須明確同意。

### 0.3 文件維護規則

- 已確定的範圍：§1／§4／§6；工作包與依賴：§5；執行驗收的方法：§8。新的需求先更新對應契約及工作包，不再於頁首堆疊多份補充決策。
- 工作包 W0–W11、M1–M4、MT1–MT3 與正文 §1–§9 編號保留。歷史證據從原 §5.1／§5.2／§5.4 移至附錄 A，原節保留可點擊證據索引。
- 本文件不取代 [PROJECT.md](../architecture/PROJECT.md) 的資料／發佈安全要求、[README.md](../USER_GUIDE.md) 的建置入口及 [WORK_LOG.md](../history/WORK_LOG.md) 的逐次工作記錄。
- 工程、target／scheme、App 品牌與來源目錄已正式更名為 `IINA-ANI`；Swift module 為 `IINA_ANI`。歷史驗收中的 `IINA+` 產物與路徑保留原文，不能當作新名稱的建置證據。Bundle ID 與既有 Core Data 資料目錄仍保留，詳見 PROJECT。


<a id="plan-scope"></a>
## 1. 目標與範圍

做一個有辨識度、可長期自訂的 macOS 影音資料與播放入口：日常發現 → 搜尋作品／影片 → 查看資訊 → 選來源／集數 → 播放或下載 → 收藏與再次訪問。預設介面完整好用，不要求使用者先調整主題。

| 使用者需求 | 基礎功能先交付 | UI 整合後交付 | 工作包 |
| --- | --- | --- | --- |
| 原有解析及統一 source 接口 | 統一入口、既有來源遷移、有限配置規則、真實播放 | 來源選擇、詳情、集數／線路／品質操作 | W1、W3 → W9 |
| 基礎信息獲取同步（Bangumi） | 作品／集數資料、快取、刷新、關聯命令 | 資訊展示、搜尋結果、手動關聯操作 | W4 → W9 |
| 收藏分兩欄 | 作品／連結兩類資料、去重、排序、舊書籤遷移 | 真正雙欄、各欄搜尋與排序、欄寬記憶 | W5 → W9 |
| 網站號池、下載與快取設定 | 帳號隔離、憑證生命週期、偏好保存、快取清理及目錄策略 | 來源與帳號、播放、下載與快取設置頁 | W2、W6 → W9 |
| 下載進度 | 真實下載任務、可觀察進度、恢復、完成檔案 | 任務清單、進度及操作按鈕 | W6 → W9 |
| Torrent 下載與邊下邊播（新增） | libtorrent-rasterbar 2.1.2、magnet／torrent 匯入、精確選檔、恢復、受控 Range 串流 | 匯入／選檔、共用下載任務、buffering／錯誤與上傳政策 | W11.1–W11.3 → W11.4／W9 |
| 瀏覽搜索 | 關鍵詞／URL 路由、來源搜尋、作品搜尋、分頁與取消 | 共用搜尋框、結果頁與詳情導航 | W3、W4、W7 → W9 |
| 日常更新推薦 | 排期、收藏更新比較、可解釋推薦與跨日刷新 | 發現頁各分區與更新標記 | W7 → W9 |
| 可替換與分享的 Skin | 功能服務不依賴外觀；Skin／Layout／偏好分離 | 深淺色、素材／字體／組件狀態樣式、預覽、.iinaskin 匯入／匯出與作者流程 | W8.2、W8.4 → W9 |
| 組件自由編排與可選功能 | 唯一業務 owner、功能能力及依賴；隱藏不停止任務 | 跨頁／跨欄拖曳、尺寸、可選組件、撤銷／還原、重啟保存 | W8.1、W8.4 → W9 |
| 腳本配置頁面佈局 | 受限執行只輸出 Layout，不接觸帳號／檔案／網路 | JavaScript 生成巢狀／斷點佈局、預覽、手動續編；與拖曳共用模型 | W8.3、W8.4 → W9 |
| 設定好上手、少步驟 | 偏好與組件實例狀態邊界明確 | 五組淺層設定、搜尋直達、就地操作、固定恢復入口 | W8.4 → W9 |

「基礎信息同步」在本階段指 Bangumi → 本機的作品資料更新，不擅自延伸為帳號收藏或觀看進度雙向同步。預留外部作品 ID，不預建通用同步引擎。若後續增加雙向同步，需另外定義授權、刪除、衝突及播放器事件語義。

本階段不做：任意原生／業務插件、無限制腳本執行、Skin／插件市場、內建圖片／字體繪製工具、雲端帳號系統、機器學習推薦、下載直播錄影、DRM 解密、另造播放器或替換儲存引擎。組件拖曳、外觀編輯、Skin 包及受限佈局腳本已納入 §6.3；不把 UI 腳本擴張為來源解析腳本，也不刪除既有直播與彈幕。

<a id="plan-evolution"></a>
## 2. 現況與演進原則

現行組裝沿用 2026-10-10 依賴整理：AppDelegate 擁有 AppServices，集中服務生命週期；來源上下文明確注入、搜尋／解析狀態由各畫面持有，播放編碼與持久路徑獨立。服務不反向依賴 Skin／Layout。

已核對的程式入口：

- `IINA-ANI/Features/Sources/SupportSites.swift`：站點分類及 `SupportSiteProtocol`；目前核心方法是 `liveInfo`、`decodeUrl`。
- `IINA-ANI/Features/Sources/Decoders/VideoDecoder.swift`：W1 共用入口為 `selection(for:)`、`inspect(_:directly:)`、`resolve(_:)` 及 `prepareVideoUrl`；W3 經 `SourceRegistry` 分類及能力檢查，分派配置引擎或原生適配器，保留 B23、番劇、直播房間、代理及品質的原生處理。
- `IINA-ANI/Features/Sources/YouGetJSON.swift`、`Processes.swift`：既有媒體結果與播放協調邊界，不能把 UI 重構當作替換播放協議的理由。
- `IINA-ANI/Core Data/`：既有書籤與版本化模型；沿用並演進。
- `BiliBangumi.swift` 是 Bilibili 番劇解析，不是 Bangumi（bgm.tv）元資料服務。
- 既有來源的建置、解析、媒體解碼與視窗驗證程度不同，以 [WORK_LOG.md](../history/WORK_LOG.md) 為準；不得統稱全部站點已驗收。

決策：完整重做使用者可見的主介面及設定體驗，但不全面重寫服務。保留 AppKit 視窗生命週期與既有播放器／WebKit 邊界，新頁面優先沿用現有 SwiftUI 整合方式；先讓基礎功能透過既有入口或臨時驗證程式運行；W7 通過功能整合關卡後，才在 W8／W9 製作新視窗、主題與雙欄。避免先改工程啟動方式。macOS 13.5 仍是工程相容目標，不引入未提供相容處理的新系統限定功能。

基礎階段不刪除仍在使用的舊 UI，也不增加第二套業務實作；已遷移的服務須讓既有呼叫端改走同一入口。進入 UI 階段後按頁面垂直切換；每個入口只有一套有效路徑。遷移完成後移除該入口的舊控制器、Storyboard 連接與冗餘分派，不永久保留「新版／舊版」兩套產品。刪除前檢查資源、選單、URL 開啟、本機 HTTP API、彈幕外掛及全部呼叫端。

<a id="plan-contracts"></a>
## 3. 模塊耦合與資料契約

本節先定義被真實功能使用的契約，再隨各基礎模塊落實；不先建立空協議、通用框架或多層 DTO。下圖為最終依賴方向，頁面、Skin 與 Layout 到 W8／W9 才實作；Theme 是 Skin 解析後的外觀值，其他服務不得反向依賴外觀或佈局。

原則：功能在用例層整合，UI 及外部站點彼此解耦；不讓每頁直接呼叫站點或持有 Cookie。不拆微服務、不引入全域事件總線。

```text
頁面／路由 ── Layout（排列）＋ Skin → Theme（外觀值）
    │
    ├─ 發現／搜尋用例 ── Bangumi + SourceRegistry + 收藏讀取
    ├─ 詳情／播放用例 ── 作品關聯 + SourceRegistry ── 既有播放器／彈幕
    ├─ 收藏用例 ────── Core Data
    ├─ 下載用例 ────── SourceRegistry + 下載任務儲存 + 檔案
    └─ 設置用例 ────── Skin／Layout + 號池 + Preferences + 快取管理
                               │
來源請求 ── 指定來源及帳號上下文 ── 憑證儲存
```

以下為目標契約；W1 已實作 `Work`、`Episode`、`SourceItemRef`、`WorkSourceLink`、`PlayableSelection` 及既有解析結果的演進，W2 已實作 `SiteAccount`、使用 lease、下載策略與 owned-cache 計量／命令；其他契約仍按工作包推進。不為對齊本文額外包裝一層。

| 契約 | 最小資料／行為 | 擁有者及禁止事項 |
| --- | --- | --- |
| `Work` | 本機穩定 ID、可選 Bangumi ID、標題／別名、封面、年份、簡介、資料更新時間 | 元資料服務更新外部資訊；不能覆盖本機收藏狀態或手動關聯 |
| `Episode` | 作品 ID、外部集數 ID（若有）、類型、標籤與排序 | 正篇／SP／第 0 集分開識別，不能只靠陣列下標跨站對集 |
| `SourceItemRef` | source ID、站內內容 ID或規範頁面 URL、內容種類 | 來源註冊中心解讀；不拿短效串流 URL 作永久身份 |
| `WorkSourceLink` | Work ID、來源作品引用、已確認的集數映射 | 作品關聯用例管理；同名不自動認定同作品，模糊匹配僅給候選 |
| `PlayableSelection` | 來源項、集數／分 P、線路、品質、選定帳號 ID | 播放及下載共用解析輸入，UI 不構造認證 header |
| 解析結果 | 串流候選、媒體類型、必要請求上下文、可選到期時間、播放器／下載／彈幕能力 | 演進既有 `YouGetJSON`／Stream 邊界，站點原始 JSON 不流入頁面 |
| `Favorite` | 作品型：Work ID；連結型：規範頁面 URL＋原始 URL；建立時間與排序 | Core Data 為唯一真相，不在頁面各存一份收藏清單 |
| `DownloadTask` | 任務 ID、原始選擇、目標路徑、狀態、已完成量、可選總量、錯誤摘要 | 下載管理器唯一擁有；UI 只發命令／讀狀態，不依賴解析 URL 永久有效 |
| `SiteAccount` | source ID、帳號 ID、顯示名稱、啟用／有效狀態、憑證引用 | 號池管理；密鑰放安全儲存，主題、一般偏好及日誌不得含憑證 |

一致性規則：

1. 頁面保留查詢、選中項等短期狀態；收藏、任務、帳號、主題由各自唯一擁有者保存。共享變化透過型別化觀察更新，不互相操作 View。
2. 快速連續搜尋時取消舊請求，且只接受當前查詢的結果；取消不是失敗。不把搜尋取消傳遞給已獨立啟動的播放或下載。
3. 任務使用啟動時的來源、帳號及目標路徑；改設置僅影響新任務。登入失效停止該任務並提示處理，不悄悄換另一個人的帳號。
4. 只有外部 I/O 邊界負責轉換原始錯誤；用例以無結果、需登入、權限不足、暫時不可用、不支援、資料不完整等可操作分類呈現。不能把不同失敗全變成空列表。
5. 不確定總量、發布日期或集數時明示未知；不填 0、今天或猜測集數冒充成功資料。

<a id="plan-services"></a>
## 4. 基礎功能規格

本節定義服務的目標行為與最終完成條件。已交付範圍見 §5／附錄 A；尚未驗收項不可用 mock、空協議或預置 UI 資料結案。§0.2 已恢復正式 App、播放器與真實傳輸驗收，按 §5.5／§8 執行。

### 4.1 偏好、網站號池與快取基礎

先實作服務與儲存，不先做設置頁；主題資料及外觀選項留在 W8，不成為來源、收藏或下載的依賴。

- 偏好：沿用既有設定儲存方式，提供來源啟停、預設帳號、播放器、品質／彈幕、下載目錄與併發數的讀寫。保留既有功能邊界，不擴充播放器範圍。
- 帳號：服務保留網站／身份隔離、既有預設身份與任務綁定；2026-10-13 起設定只提供三站登入狀態及登入／登出，移除號池、新增、啟停、移除與預設選擇 UI。取消重用待登入身份，不清除其他舊身份或自動輪換；直播／影片來源窗口只讀登入狀態，活動任務維持捕獲的帳號。
- 憑證：保留已支援站點的登入方式；憑證及 Web 登入容器按站點／帳號隔離。需要網頁登入時重用既有登入視窗或必要的最小驗證入口，不要求新設置頁；不建立假登入狀態。網站無可用登入接口時明示不支援。
- 下載策略：目標目錄、併發數、任務暫存位置先作為可讀取的設定；變更只作用於新任務，不搬動正在下載或已完成的檔案。W6 使用這份策略，不另存一套。
- 快取：區分可重建的封面／元資料、下載中的暫存及已下載檔案。提供大小、上限及清理命令；上限淘汰只作用於可重建快取，不刪收藏、帳號、任務及完成檔案。任務模塊直接管理自身暫存，不先建通用資源鎖框架。
- 帳號移除：提供「仍被任務使用」的拒絕原因，先停止任務才能移除。W2 驗證帳號生命週期及依賴使用方的約定；W6 實作任務引用，W7 串接驗收。不讓移除操作暗中切換工作身份。

驗收：同站兩帳號的請求身份一致且 Cookie 隔離；登入失效可重新授權；停用／移除不影響其他帳號。偏好重啟仍在，清理可重建快取不碰持久資料；請求、日誌及一般偏好不含明文憑證。涉及真實下載中的清理保護、使用中帳號移除及新目錄策略，由 W6／W7 驗收，不以空任務假證明。主題匯出的去敏驗收留到 W8。

### 4.2 原有解析與配置式 Source

統一來源入口在現有 `SupportSiteProtocol` 及 `VideoDecoder` 上演進，集中提供：辨識／規範 URL、資訊、集數與線路、解析。搜尋、瀏覽、下載、彈幕為明示能力，不要求每站實作無意義的空方法。服務明示能力與不支援原因，UI 階段再據此呈現操作；播放與下載共用相同選集身份。

配置目標：`source ID`、名稱、版本、host／path 匹配、能力、請求模板、HTML 選擇器或 JSON 路徑、集數／線路映射、直連媒體提取與既有命名處理器選擇。配置可引用帳號上下文，但不內嵌 Cookie 或 token。

**「只加配置」的保證範圍**：現有規則引擎可描述的 HTML／JSON、有限固定資料轉換、公開直連媒體來源。遇到簽名、複雜挑戰、特殊代理或私有協議，增加或保留原生適配器；不得為承諾所有站點零程式碼而引入任意 JS 執行平台。

**2026-10-12 追番來源定位與訂閱更新**：後續逐站接入原為測試，產品重點是一站式追番；站點是可替換背景來源，不要求清單每站可用，也不新增其網站帳號。保留現有解析器及原專案帳號功能。css1 v2 經受控搜尋規則轉換、固定身份／本地修正、差異預覽、變更搜尋實測及明確套用後，寫入獨立訂閱快照；不覆寫一般 sources/*.json、不匯入憑證／腳本、不新增未知播放能力。訂閱已切為後加番劇來源唯一搜尋／自動尋源入口，舊規則僅為轉換基線，不再回退使用；尚未套用者不啟用搜尋，缺項／失敗項僅保留先前已套用配置。原專案來源、直接網址解析、原作品／集數關聯與活動任務不改。此為既有來源公開搜尋配置的可重複更新路徑，不是全站通用解析引擎；操作與現行限制見 README「搜尋與日常更新服務」。

實施要求：

1. 先從兩個有代表性的現有簡單站點提煉共同規則，不先設計萬用抓取 DSL。
2. 從應用資源及使用者 sources 目錄載入配置；同 ID 衝突明示拒絕，不默默覆盖內建來源。配置不要求改站點 enum、UI switch 或重新編譯；來源圖示使用可選資源與通用圖示。
3. 載入時驗證版本、匹配衝突與必需欄位；外部 URL／重新導向與憑證使用按目的主機檢查，不把來源憑證發往未授權主機。
4. 舊站點可以保留原生實作，但全部改走同一 registry／入口。站點特有規則留在適配器，不進收藏、頁面或播放器。
5. 建立逐來源能力矩陣：搜尋、解析、選集、線路、品質、IINA、mpv、JSPlayer、彈幕、下載；不因「可解析」自動勾其他能力。

驗收：兩個現有站點配置化後結果與選集身份不變；第三個符合能力範圍的真實來源只新增配置、重載後即可辨識→取得資訊→選集→實際播放（由既有入口或臨時驗證程式驅動），無 Swift 或工程修改。另以一個需原生處理的来源證明同入口可共存。既有來源逐一記錄遷移結果與失效原因；既有可用能力不得因新 UI 遺失。不以返回媒體 URL 當作播放驗收。

### 4.3 Bangumi 基礎信息獲取與同步

工作：獲取作品標題／別名、封面、簡介、日期、類型與可用集數資訊，保留資料出處及取得時間。提供首次獲取、強制刷新、收藏作品排程刷新等可直接呼叫的用例；預設一天內的快取可直接使用，手動刷新不受此限制。API 路徑、授權要求及可用欄位在接入時查核官方現行文件，不從 Bilibili 番劇類別推定。

本機主鍵不隨 Bangumi 關聯改變；無匹配時建立本機作品，允許手動選擇／解除關聯。Bangumi 下線不妨礙已有收藏和來源播放。外部欄位刷新不覆盖手動名稱、來源關聯與收藏排序，必要的手動覆寫獨立保存。

驗收：首次獲取後重啟仍能讀取；刷新可更新外部資料但保留本機欄位；斷網回傳快取及時間；同名異作不被自動合併；解除／更換關聯不刪收藏、不重建作品身份；沒有資料時回傳未關聯狀態而不是偽造資訊。

### 4.4 收藏資料與遷移

工作：作品收藏按本機 Work ID 去重，關聯多個來源；有 Bangumi ID 時協助識別，但沒有 ID 也能收藏。普通影片、分 P 頁及直播按規範頁面連結保存，保留原始 URL；規範化由來源提供，不能一律刪 query 導致不同集數合併。提供兩類收藏各自的查詢、排序與刪除命令；雙欄呈現、拖動欄寬與欄寬保存留到第 6 節。

舊書籤遷移：完整保留連結、標題及原有排序，先進連結欄；可確定作品關聯的項目才轉為作品收藏，不能按標題自動合併。遷移有版本與事前備份，重复啟動不重复導入；失敗不得覆盖原資料。

驗收：同作品兩來源只形成一個作品收藏；不同集數的普通連結按站點規則保留差異；重啟資料仍在；刪除收藏不刪下載檔、不刪來源帳號；失效連結仍可查看／修改；以含普通影片、直播、劇集連結的舊資料副本驗證遷移及排序。

### 4.5 下載引擎、進度與檔案

工作：以來源、已選集數／線路／品質及帳號上下文建立真實任務，不依賴詳情頁。基線交付普通直連檔案及公開、非 DRM 的 HLS 點播；HLS 使用來源所需請求上下文，下載支持範圍由能力矩陣明示，不以播放可用推定下載可用。W6 選用可重用的成熟媒體處理路徑並記錄打包／授權要求，不自己重造通用媒體解封裝器。

狀態：`queued → resolving → downloading → finalizing → completed`；可轉 `paused`、`failed`、`canceled`。完成必須在寫入及必要封裝成功後宣告；暫停／取消在封裝階段是否可用須明示，服務須回傳允許的操作集合，供後續 UI 使用。

- 提供可觀察的作品／影片、集數、品質、進度、速度、可得的剩餘時間及狀態。總量未知時回傳已下載量／分段數及未知總量，不造百分比；封裝階段獨立標示。
- 預設同時下載 2 項，由偏好設定調整；不預設大量併發分段。任務清單持久化，重啟將中斷工作標為待恢復，不虛報正在下載。
- 支援續傳的資源驗證身份後續傳；不支援時明示重新下載，不把舊 bytes 拼入新檔。短效 URL 恢復時重新解析原始選擇，不能換成其他集數或品質。
- 目錄不可寫、磁碟不足、授權失效、媒體失效要停止並給可操作原因；不無限重試。不自动換帳號、來源或較低品質。
- 完成提供可用檔案位置及播放器開啟命令；Finder 顯示與按鈕在 UI 階段接入；檔名衝突不得覆盖既有檔案。取消清理該任務暫存，刪除記錄與刪檔為不同操作。

驗收：實際下載一個直連檔及一集 HLS，完成檔可載入、播放並定位到尾段；下載中輸出真實進度事件；暫停恢復、取消、重啟恢復、過期重新解析均驗證內容身份；未知總量、磁碟不足／不可寫目錄、檔名衝突回傳正確狀態且不損壞其他檔案。無下載能力的來源在用例入口拒絕任務並提供原因；按鈕狀態於 UI 階段驗收。

W6 的直連／HLS 驗收範圍保持不變；新增 Torrent backend、共用任務與共享檔案生命週期另見 §4.8／W11，不以本節既有完成狀態代簽。

### 4.6 瀏覽與搜尋用例

工作：搜尋用例辨識關鍵詞與 URL；作品搜尋走 Bangumi，站內影片搜尋只對宣告有能力的來源開放；結果提供全部／番劇／非番劇／一般影片／直播／未知待確認分區，保留分類出處及來源身份，不强行混為同一排名。來源可篩選，分頁／載入更多保留查詢條件。URL 直達不得依賴元資料服務可用。

驗收：以作品名取得搜尋結果及可載入的作品引用；輸入既有站點 URL 能取得資訊、選集及實際播放；無搜尋能力的來源仍能輸入 URL 解析；空結果與連線失敗不同；快速切換查詢不接受舊結果覆盖；分頁保持同一查詢與篩選。至少以一個實際可搜尋來源驗證來源搜尋全鏈，而非僅回傳 Bangumi 結果。頁面返回與滾動位置在 UI 階段驗收。

驗收依 §5.5 R1／R3：輸入提交到結果開啟走正式 App；來源局部失敗不可阻擋其餘結果，載入／空結果／錯誤分開呈現。查詢、類型、來源篩選與分頁是同一畫面狀態，取消及過期回應不得覆寫新查詢。

**類型隔離（R3 已完成）**：搜尋提供番劇／非番劇分區，非番劇保留一般影片與直播子類；資料與路由持有明確類型及分類出處，未知明示待確認。不以網站 host、標題或有無 Bangumi ID 單獨判定；混合站按具體內容分類。推薦動畫進番劇路由，普通影片 URL 不依賴 Bangumi；跨來源同名不自動合併。分類修正不重建 Work／Episode 身份、不刪收藏／下載；持久欄位沿用版本化副本遷移。[實作與正式 App 證據](#r3-classification)。番劇自動尋源契約仍待 §5.5.1。

### 4.7 日常更新與推薦用例

工作：服務輸出三組資料：「全週放送」（Bangumi 排期）、「收藏有更新」（來源實際目錄變化）、「推薦看看」（Bangumi 動畫近期注目）。2026-10-11 依使用者指定，推薦來源改為 Bangumi 日曆及 `anime/browser/?sort=trends`；不再以當季與播放來源同名匹配產生推薦。

- 全週放送以服務排期標註，不能聲稱站點已上架；來源集數增加才能標為可看更新。
- 更新比較集數身份集合，不以列表重排或數量變化直接判定；首次建立基線不將全部舊集標成今日更新。
- 日曆由官方 `https://api.bgm.tv/calendar` 取得，呈現全週七欄網格，第一行固定為「周日｜周一｜周二｜周三｜周四｜周五｜周六」，各天作品在對應欄下垂直捲動；移除星期篩選切換，右上角按鈕開啟彈窗，不佔發現頁分區；收藏更新移至收藏頁頂端，作品／連結双欄保留。發現頁第一頁 Trends 頂置，剩餘空間為垂直推薦流，從 `https://bangumi.tv/anime/browser/?sort=trends&page=N` 第二頁延續熱度順序，按 subject ID 去重。向下捲至末端自動載入，也可手動載入／失敗重試；同源 pager 決定下一頁與結束，不用複製卡片製造無限列表。理由明示「Bangumi 動畫近期注目」，不能以 `rank`／搜尋 `heat` 或當季作品冒充趨勢。推薦不依賴啟用播放來源；點選開啟 Bangumi 作品詳情，來源關聯與播放仍由使用者明確選擇。
- 全週放送頭圖改從 `https://bangumi.tv/subject/<id>` 簡介頁的 `#bangumiInfo .infobox` 擷取，優先 `a.thickbox.cover` 原圖，否則取該資訊區的 `img.cover`；正規化為 Bangumi 圖床 HTTPS URL，不採日曆 API 圖片。全週按 subject ID 去重請求封面，同日排期去重而跨日排期保留；併發上限四個，保留原排期順序與 24 小時公開頭圖網址快取；取消傳播至工作群組，單圖失敗保留作品與明確錯誤，不污染已有快取。
- App 啟動或跨日後按快取規則刷新，可手動刷新；不設常駐背景輪詢。來源比較限收藏作品，不抓全站。
- 沿用 24 小時身分快取／手動強制刷新，分頁快取隔離；過期資料与刷新錯誤一起呈現。公開趨勢請求不繼承帳號 Cookie／OAuth context；驗證頁、錯誤結構與有下一頁卻無項目的頁面回報失敗，不覆寫有效快取；正常空末頁停止載入。新增 `discovery.feed`，既有組件 ID、分區開關與 Layout 格式不變；仍符合舊三／四分區內建結構的所有斷點原子遷移，保留存續實例與設定，自訂 Layout 不覆寫。
- 卡片番名依使用者指定改為固定位置懸浮浮層：平時顯示封面，鼠標移入／鍵盤導覽選中時顯示深色毛玻璃濾鏡與白色文字，移出淡出；浮層不跟隨鼠標、不另開窗口、不用系統 toolTip 代替效果。長番名換行，名稱與來源／推薦理由保留為原生輔助資訊；新集數、錯誤及載入提示不隱藏。
- 依後續視效調整，番名底置於卡片下緣，為新集數提示留出間距；濾鏡與文字分層，毛玻璃不透明度 55%、黑色疊色 18%，保留封面細節而不降低文字透明度。
- 2026-10-13 主頁密度與本機續播：內建順序為 Trends → playback.continue → 推薦，Trends 210 pt；封面填滿卡片並縮小內外間距，推薦依寬度增加欄數。續看橫向單行直接顯示作品／集數與實際秒數、已知時長進度；空列收為 76 pt 提示。觀察 PlaybackHistoryStore.didChangeNotification，即時更新與收展；點選透過 AppServices.resumePlayback 重解析來源並從保存位置啟播。三區整合為共同縱向交互單元，前兩行不固定；推薦直接展開在共同文件，Trends／續看橫滑各自處理，縱滑捲动整個主頁。保留全部斷點舊內建形狀的既有遷移、組件身份、導航、折疊與私有呈現狀態，自訂 Layout 不覆寫；播放歷史不放入分享 Skin／Layout。實播證據與限制見 WORK_LOG.md 的本機续播記錄，本輪只改主頁交互。
- 普通瀏覽的鼠標左鍵拖動只捲動內容，不更改排序；Trends／續看橫向拖動各自處理，主頁各區縱向拖動共用整頁 owner。原生 pan 與 click 有失敗優先序，拖動不得誤觸續播／詳情；輸入、文字選取、表格拖曳與 split 分隔線保留原生事件。拖動編排保持在「編輯佈局」按鈕後的獨立草稿／保存流程。
- 空白拖動接收範圍與視覺面板一致：標題旁／邊距由 WorkspaceDragRegionView 指向所屬捲動 owner，首頁跨分區間隙由共同外層接收縱向拖動。點擊門檻仍由原生 pan 識別維持，不把所有左鍵按下都當成拖動。

驗收：給定固定日期及輸入資料，分區與排序可重現；跨日重新計算；收藏新增集產生一次更新事件、重排不重複報新；標清排期與來源更新的差別；某來源故障只影響對應資料項，其他分組可用；無資料時回傳明確空結果而非假推薦。卡片與分區展示在 UI 階段驗收。

### 4.8 Torrent 下載與邊下邊播（W11.1–W11.3 已驗收；W11.4 UI 已隨 W9 整合，MT3 未簽收）

2026-10-09 使用者確認加入 Torrent 支援，核心固定為 **libtorrent-rasterbar 2.1.2**，上游 tag `v2.1.2`／commit `6da363d2994f17c0b3c0450d124cf73a31a73847`。本節新增獨立工作包 W11，不重寫 W6／W7 歷史驗收，也不把已交付的 HTTP／HLS 下載宣稱為已支援 BT。

**交付範圍**

- 匯入 magnet URI 與本機 `.torrent`；取得 metadata、列出多檔 torrent、明確選定媒體檔，支援 v1、v2-only、hybrid。metadata 未取得、無 peer／缺塊、檔案不可播放與一般網路錯誤分開呈現，提供取消與有界等待，不以空列表或假進度掩蓋失敗。
- 選定檔案可建立持久下載任務，亦可在未下載完成時透過受控 loopback HTTP Range 串流交給既有外部 IINA／mpv；完成檔仍走既有開啟命令。Torrent 核心不替代播放器或通用解封裝器。
- 來源發現與傳輸分離：Mikan／DMHY 等網站搜尋、RSS 自動訂閱、PikPak 雲端離線、遠端 BT daemon 管理及新彈幕來源不自動納入；後續新增網站仍須獨立適配與驗收。Torrent 的 JSPlayer 能力在未實測前明示不支援，不受既有預設能力誤開放。
- 本次是對「W7 新增下載限 css1.json」的明確新增 Torrent 範圍，不擴充 Bilibili／Douyu 或其他網站下載；既有 W2／M2 有效帳號門檻維持。

**整合與持久化契約**

- 原生嵌入，使用薄 Objective-C++／C ABI 邊界對接 Swift；C++ 例外、型別及記憶體所有權留在橋接層，不引入 JVM／JNI、Python runtime 或另一套核心。以 C++17／CMake 固定原始碼與依賴版本，產物納入現有 App 工程。
- `DownloadService` 保持唯一下載任務 owner；Torrent backend 管理 native session／handles，提供同一任務快照、進度、允許操作與錯誤模型。不另設下載資料庫或平行 UI；metadata 與 resume 檔是任務私有附件，不是第二套任務真相。
- 持久身份使用帶算法標記的 v1／v2 infohash 集合、metadata 中的 file index、路徑與大小；hybrid 不因兩個 hash 生成重複任務。播放、下載、收藏及 Work／Episode 關聯共享同一選檔身份；重開後精確檔案不存在或 metadata 不符就明示失敗，不回退第一個影片或用陣列位置猜集數。不持久化短效 loopback URL。
- 同 torrent 的播放與下載共用 transfer/session 使用權；各 reader 可獨立取消，seek 的 deadline 合併／撤銷不能破壞其他 reader。關播放器不停止獨立下載；取消下載不刪其他播放仍使用的資料；最後一個使用者釋放後才停止相應 transfer，App 退出等待 native writer／回調結束。
- resume 與 metadata 原子保存於 owned 資料區；正常退出及強制終止重開需恢復原選檔／目錄與完成 bitmap。缺失、過期或損壞 resume 應重新校驗真實資料，不能虛報完成；進度以選定檔案已校驗 bytes 計，不把其他檔案、邊界共用 piece 或協議傳輸量當完成量。
- 保留 W6 的目錄快照、bookmark、檔名衝突、刪記錄／刪檔分離及快取保護。多檔 torrent 的路徑 traversal、絕對路徑與 symlink 不得越出 owned 目錄；共享 piece 帶來的附帶資料留在私有區，不冒充使用者選擇下載其他檔案。
- P2P 下載期間可能上傳資料，入口明示此行為；提供有效的上傳限速及停止命令，完成後預設不持續做種，亦不在 App 關閉後留常駐程序。不得把 BT 下載描述成純接收；private torrent 尊重禁止公開發現的限制，不洩漏 tracker passkey／magnet 敏感參數或套用網站 Cookie。

**HTTP 與 native 讀取邊界**

延用 NIO loopback server；HTTP byte range 映射至所選檔案的 torrent piece offset，以 deadline 優先取得目前讀取區域，不能僅用 sequential download。只回傳已校驗 bytes，等待缺塊時不送零值或假 EOF；保留有界緩衝與背壓，不把整片載入記憶體。正確處理 HEAD、完整 GET、單一 Range（含開放尾端／suffix）、206／Content-Range／Content-Length、416；多重 Range 按 HTTP 規範明確處理，不產生錯誤的單段 206。

用 `set_piece_deadline(..., alert_when_available)`／`read_piece_alert` 處理缺塊及已完成塊的讀取；集中分派回調，避免先查狀態後訂閱的漏接。HTTP 斷線、seek 替換、無 peer 逾時與取消須解除相應等待，晚到回調不得回寫已結束 reader。URL 綁定不可猜測、有限生命週期的播放授權，只開放已登記的 torrent／file，不提供任意本機路徑或無認證管理介面；停止播放及 App 退出撤銷授權。

**相容與授權門檻**

依 App 支援架構建置、檢查所有 dylib／rpath／最低系統，維持 macOS 13.5，不直接捆綁本機 Homebrew 或 Python wheel。BSD-3-Clause 與現有 GPLv3 配合時保留上游聲明，核對 Boost／加密庫等實際依賴授權；簽署、公證及獨立 fork 身分沿用 PROJECT 的發佈關卡。缺少最低系統或簽署環境時標未驗證，不以提高部署目標繞過。

選型來源及早期 Python binding 2.1.1 煙霧的適用限制移至 [附錄 B.2](#research-torrent)；不得用該研究替代 W11 的 App-linked 2.1.2、播放器或最低系統驗收。


<a id="plan-work"></a>
## 5. 工作拆解、依賴與階段關卡

本節只列工作包、前置依賴與完成門檻；執行證據集中於附錄 A。狀態摘要見 §0.1，所有實播／整體驗收的執行時序受 §0.2 約束，不將本節原定門檻當成現在啟動 App 的指令。

### 5.1 階段 A：基礎模塊實作

| 工作包 | 任務與交付 | 前置依賴 | 完成門檻 |
| --- | --- | --- | --- |
| W0 基線與資料盤點（已驗收） | 來源／播放器能力矩陣；選單、URL、HTTP、書籤入口；隔離資料副本及舊 UI 證據；[交付記錄](FRONTEND_W0_BASELINE.md) | 無 | 每個既有入口有服務遷移位置；區分歷史失效與回歸；資料可還原；已完成基線建置與功能煙霧驗證 |
| W1 最小契約與持久化基礎（已驗收） | Work／Episode／來源身份及選擇契約；實際 Core Data v0.4 保存、重讀與舊模型遷移；共用解析入口及全部既有呼叫端切換 | W0 | 身份／映射重讀及舊書籤遷移通過；真實主介面選集、品質及 libmpv 媒體視窗載入；取消／替換搜尋不影響獨立播放。證據見附錄 A |
| W2 偏好、號池與快取（實作交付；真實登入驗收待補） | 設定讀寫、帳號及 Keychain／Web 登入隔離、登入生命週期、可重建快取清理、下載目錄／併發策略；證據見附錄 A | W1 | 已完成可執行隔離／持久化／清理回歸及現有入口煙霧驗證；第 4.1 節真實雙帳號與重新授權仍待人工完成，任務串接列入 W6／W7 |
| W3 統一來源與配置引擎（已驗收） | 全部既有站點走 registry／入口；Fqdm、Forest 配置化；Internet Archive 純配置及真實播放；來源搜尋／能力與逐站結果見附錄 A.3 | W1、W2 基礎服務 | 第 4.2 節通過；真實 libmpv 視窗及原生 App 入口驗證，不推定所有遠端媒體／播放器已通過 |
| W4 Bangumi 元資料（已驗收） | 作品搜尋、資訊／全部類型集數、快取刷新／離線、本機關聯與排期；既有設定入口改為 Bangumi 單一個人帳號 OAuth | W1、W2 | 第 4.3 節通過；真實獲取、持久化、獨立程序重開、模擬斷網及更換關聯已驗證；有效個人授權未以合成 token 冒充 |
| W5 收藏與遷移（已驗收） | Core Data v0.5 的作品／連結收藏、來源關聯、去重、查詢、排序／編輯／刪除、舊書籤 WAL 一致備份／版本化遷移／還原；證據見附錄 A | W3、W4 | 第 4.4 節通過；真實資料副本、跨程序重開、身份與刪除隔離驗證完成；雙欄 View／欄寬留給 W9 |
| W6 真實下載（已驗收） | 直連檔／有限非 DRM HLS、任務状态與進度、排程／持久化、恢复／原選擇重新解析、帳號 lease、目錄策略及獨立檔案命令；證據見附錄 A | W2、W3 | 第 4.5 節通過；公開完成檔經實際開啟 API 解碼／播放及定位尾段；重啟、暫停／取消、401、真實磁碟／權限與衝突可運行，不依賴進度頁 |

歷史證據：[W1](#a-w1)／[W2](#a-w2)／[W3 與逐來源矩陣](#a-w3)／[W4](#a-w4)／[W5](#a-w5)／[W6](#a-w6)。表內完成門檻是原契約，已執行樣本及未驗證範圍以附錄為準。

基礎依賴維持 W0 → W1 → W2 → W3／W4 → W5／W6 → W7；W2 未簽收項不因其他工作包已有交付而自動完成。


### 5.2 階段 B：跨模塊功能串接

本階段將 W0–W6 接成可由既有入口呼叫的用例，重點是身份不變、狀態所有權明確及重開可接續，不是新增頁面或重造服務。以下細分為 W7 的工作／補驗對照，不重開已交付範圍，也不代表本次新增實作。現行組裝以 §2 為準，附錄 A.7 的歷史 owner 名稱不作新呼叫端接線規範。

| 工作包 | 任務與交付 | 前置依賴 | 完成門檻 |
| --- | --- | --- | --- |
| W7 搜尋、日常更新與功能整合（目前指定範圍已交付） | 第 4.6／4.7 節服務；搜尋→作品→來源→播放→收藏／重開；清單來源 guest 解析→下載／恢復；設定→任務／快取 | W3、W4、W5、W6 | 真實資料閉環證據見附錄 A.7；使用者限定下載清單，原 M2 有效網站帳號下載門檻保留，未自行開工新 UI |

#### 5.2.1 W7 子包與交接成果

| 子包 | 串接與交付邊界 | 依賴／交接 |
| --- | --- | --- |
| W7.1 搜尋與 URL 直達 | 關鍵詞分流 Bangumi／有搜尋能力的來源；保留結果類型、來源身份、篩選及分頁條件。普通 URL 直接走來源解析，不等待 Bangumi | W3、W4；交付作品或來源引用，不把搜尋列下標當身份；無搜尋能力不等於不可解析 URL |
| W7.2 作品、来源與播放／收藏 | 讀取元資料、確認來源關聯、選集／線路／品質；同一選擇交給既有播放準備鏈或收藏命令，收藏後由持久層重讀 | W7.1、W5；Work／Episode／來源映射在重開後不變；普通影片保存連結收藏，無須強造 Work |
| W7.3 下載與恢復 | 原選擇及明確 guest／帳號身份交給下載服務；保存目標路徑與狀態，恢復時依原選擇重新解析；完成檔走既有開啟／定位命令 | W2、W3、W6，沿用 W7.2 選擇契約；下載限指定清單與既有基線，不由播放可用推定下載可用 |
| W7.4 日常資料聚合 | 今日排期、收藏新增集及有理由的推薦；首次基線、跨日刷新、去重及來源故障隔離依 §4.7 | W3、W4、W5；交付分組資料與局部錯誤，不把排期或同名候選標成已上架／已確認關聯 |
| W7.5 偏好、號池與快取保護 | 新任務使用新策略；活動／恢復任務保留原身份及路徑；清理限可重建資料，使用中帳號移除由 lease 阻擋 | W2、W6、W7.3；呼叫端取得拒絕原因，不靠設置頁推算是否安全 |
| W7.6 入口與證據收口（實作／單元交付；整體驗收未簽收） | 既有 UI、URL／HTTP、書籤及播放器／彈幕入口沿用同一服務；依 M2 核對成功、取消、局部失敗及重開 | 彙整 W7.1–W7.5；入口 owner 與 W8／W9 交接見 §5.2.5，證據見 A.7.1；M2 未簽收項保留 |

先核對 W7.1／W7.2 的身份與選擇，再處理 W7.3／W7.5 的任務保護；W7.4 可在既有收藏／元資料契約上獨立推進，最後由 W7.6 收口。已交付部分只修可定位的缺口；Torrent 共享任務、reader 及產品入口仍歸 W11，不併入 W7 擴大結案。

**2026-10-10 W7.1／W7.2 補齊交付（單元／編譯層級）：**

- W7.1：沿用畫面獨立的 `BrowseSearchService` 與 URL 直達路由；Bangumi 按 subject ID、來源結果按 `SourceItemRef` 去重，保留首次出現順序與各自遠端游標。同名不同身份不合併。Bangumi／來源分頁失敗均交付錯誤及先前結果，首次失敗不偽裝空結果；不將失敗改成成功。取消／替換查詢沿用 generation 與 worker cancellation。
- W7.2：沿用 `BangumiWorkSync`、`WorkLibrary`、`FavoriteLibrary` 的元資料／明確關聯／收藏持久層，不新增 schema 或 UI owner。Bilibili 目錄與 API 播放取址共用精確 BV／分 P 選擇，av 經回應解析為 BV；目錄重排不改選擇，缺少指定分 P 不退到第一項。HTML 回應若屬其他分 P 或原分 P 消失即拒絕；單集仍保留影片標題。Bangumi 明確 ep 缺失即報錯，ss 作品入口仍可開啟目錄。
- 驗證：`bash Tests/run-w7-usecases.sh` 納入搜尋、精確播放選擇、元資料同步、收藏重讀及既有來源／日常單元；另通過 `bash Tests/run-work-library.sh` 與 `bash Tests/run-dependency-regression.sh --unit`、Debug arm64 必要建置。搜尋重複身份與 HTML 錯分 P 已取得修正前失敗／修正後通過；本地目錄解析小程式輸出所選分 P／CID 與缺項拒絕，不連真實站點。
- 邊界：這是既有 W7.1／W7.2 的缺口修补及交接，不取代 A.7 歷史實播，也不表示串接變更後 M2 整體驗收已重做。未啟動 App／播放器／真實傳輸、未開工 W8／W9；W2 與 M2 未簽收項保持不變。

**2026-10-10 W7.3–W7.5 補齊交付（單元／編譯層級）：**

- W7.3：核對並沿用 `DownloadService`／`DownloadSourceResolver`，不新增第二套下載用例。新增離線狀態回歸，覆蓋原集數／線路／品質／帳號重新解析、活動狀態重讀轉為待恢復暫停、清除過期速率／ETA，以及完成檔取址、刪檔與保留記錄；不把回傳完成檔 URL 當作實播。
- W7.4：交付時使用今日排期、收藏來源新增集與附理由的當季待確認推薦，並排除不存在的日曆日期；2026-10-11 推薦已依 §4.7 切換為 Bangumi 趨勢順序，不再限制作品季度或日期。首次基線、同日快照／強制刷新、跨日、持久 seen 去重、分區局部錯誤及取消不提交仍由離線回歸覆蓋。
- W7.5：新任務採新輸出／暫存目錄與併發快照，恢復任務仍保留原策略；暫停／恢復保留 account lease，取消釋放，原帳號失效／移除回報 authorization 而不改 guest，明確 guest 不採新預設帳號。快取清理／淘汰前檢查已知下載目錄與可重建根的路徑重疊（解析 symlink 別名），有重疊即拒絕且不部分刪除。
- 驗證：`bash Tests/run-w7-usecases.sh` 現含八組服務單元及快取檔案系統回歸；`bash Tests/run-dependency-regression.sh --unit` 四組通過；Debug arm64 建置通過。無效日期與快取誤刪均取得修正前失敗／修正後通過；測試僅使用注入資料、隔離偏好與暫存資料。
- 邊界：本次未新增網站下載、未改 Torrent 範圍、未啟動 App／播放器／真實網站或傳輸。W2 真實雙帳號／重新授權及 M2 有效網站帳號下載／使用中移除仍未簽收；W7.6 整體收口與 W8／W9 不併入本次。

#### 5.2.2 串接不變量與失敗邊界

以下是 §3 契約的跨模塊檢查點，不新增通用協議、全域事件總線或平行資料模型：

- **查詢與取消：** 每個畫面獨立擁有搜尋／解析狀態；換關鍵詞或來源篩選使舊查詢及游標失效，晚到結果不能覆寫新狀態。取消搜尋不取消已獨立啟動的播放／下載；單站失敗保留其他成功結果，空結果、失敗與取消分開處理。
- **身份與選擇：** 跨模塊傳遞穩定引用及原選擇，不保存短效串流 URL 作身份。同名只提供候選；缺集或原線路／品質消失時回傳原因，不暗換第一集、其他線路或較低品質。
- **帳號與恢復：** 來源服務取得帳號上下文，呼叫端不拼 Cookie；guest 是明確身份，不是登入失效的回退。重新解析仍用原帳號，失效須提示重新授權；HLS 沿用 W6 重新下載分段策略，不宣稱任意位元組續傳。
- **持久資料與清理：** 收藏、任務及日常 seen 基線不歸可重建快取；清快取不能刪活動 writer、暫存下載或完成檔。改目錄只影響新任務，重開不重定位舊任務；一般設置與日誌不得保存憑證。
- **日常更新：** 排期刷新與來源目錄比較分開；來源失敗不能當空目錄覆蓋成功基線。按集數身份去重，重排／移除後再出現不重複報新；保留推薦理由與待確認關聯。
- **入口與能力：** 來源能力決定可用命令，解析成功不代表可下載或有彈幕；未支援與遠端暫時失效分開回報。UI 消費用例與狀態，不反向成為服務依賴。

#### 5.2.3 M1／M2 關卡與未簽收項

**M1：基礎模塊完成（W0–W6）。** 要求各模塊具有可運行實作，不是接口草稿或建置空殼；W2 待簽收項仍保留，不能由已交付狀態推定完整 M1 已通過。

**M2：功能閉環完成／UI 開工關卡（W7）。** 原門檻如下；目前未完整簽收，執行時序按 §0.2，不於此自行解除前置：

1. 搜尋作品 → 讀取 Bangumi 資料 → 確認來源關聯 → 選非第一集／線路 → 實際播放 → 收藏 → 重啟重讀，無新頁面也能運行。
2. 輸入普通影片 URL → 解析 → 保存連結收藏 → 再播放；Bangumi 斷網不影響。
3. 指定網站帳號 → 解析 → 下載直連檔／HLS → 中斷重啟 → 恢復 → 完成檔播放，身份與品質不變。
4. 在真實下載進行時改目錄、清快取、嘗試移除使用中帳號；既有任務資料不被破壞，阻擋原因可由呼叫端觀察。
5. 固定日期與收藏資料驅動排期、更新比較及推薦；可區分排期與來源新增集，來源故障不使全部結果失效。
6. 配置來源、舊資料遷移及既有播放器／彈幕路徑須有對應運行證據；目前延後整體驗收不等於已通過。

當前缺口按下表處理；歷史成功樣本不因本次補充失效，也不外推成全站／全播放器通過：

| 關卡 | 現有證據可採認範圍 | 尚需處理／簽收條件 |
| --- | --- | --- |
| M1／W2 | 偏好、號池、lease、快取實作與既有登入確認 | 完整真實雙帳號隔離及失效後重新授權仍待簽收，不能以合成憑證替代 |
| M2-1／2 | A.7 作品／普通 URL、選擇、收藏、獨立程序重開及 libmpv 媒體視窗樣本 | 保留歷史證據；串接變更後補驗受影響鏈路，不外推為官方播放器完整相容性 |
| M2-3 | guest 直連／HLS 下載、重開、重新解析及完成檔播放 | 有效網站帳號下載仍缺。指定清單無可用帳號提供者；須先取得符合既定範圍的真實支援條件，否則保持阻擋，不自行擴充 Bilibili／Douyu 下載或把 guest 改稱帳號 |
| M2-4 | 活動 HLS 的目錄／快取保護及 DownloadService lease 回歸 | 真實有效網站帳號在使用中拒絕移除的人工驗收仍缺，與 M2-3 一併保留；單元只能證明狀態規則 |
| M2-5 | 真實排期／收藏基線樣本及固定日期、去重、故障／取消回歸 | 聚合邏輯變更補對應單元；頁面分區呈現屬 W9，不提前宣稱完成 |
| M2-6 | W0–W6 配置、遷移、播放器／彈幕歷史證據及 A.7 建置／回歸 | 依受影響入口補驗；全部播放器、完整彈幕與最低系統等未覆蓋項仍留待對應整體驗收，不由文檔更新補簽 |

**UI 交接不等於關卡簽收。** §0.2 只調整驗證時序，不把 M1／M2 未簽收改成通過，也不在本節自行授權 W8 開工；W8／W9 可引用本節契約作規劃，實際開工仍依 §5.3 及明確的階段決策。

#### 5.2.4 驗證時序與完成記錄

- **現行驗證：** §0.2 已恢復正式 App 驗收。結構單元入口 `bash Tests/run-dependency-regression.sh --unit` 覆蓋播放編碼、來源 registry／本地身份、Range 邊界及偏好快照，但不涵蓋全部 W7，不能作 M2 簽收證據。搜尋／日常規則沿用 BrowseSearchRegression.swift、DiscoveryRegression.swift、SourceSearchRegression.swift，依受影響路徑執行。
- **正式旅程：** 使用正式 App、本機接口或必要臨時命令入口驅動 M2 六條旅程，不新增永久 debug 頁或第二套服務。必要帳號登入與播放器走真實視窗；完成檔須實際開啟與定位，不以百分比或 URL scheme 呼叫代替播放。
- **證據欄位：** 每項記錄日期、建置／執行環境、來源與 guest／帳號模式、原選擇、操作序列、預期及實際結果、去敏證據位置、未覆蓋範圍。重開區分同程序重讀與獨立程序恢復；帳號只記不含憑證的識別，不記 Cookie、token 或完整簽名媒體 URL。
- **結案規則：** 實作交付、單元通過、歷史樣本驗收與完整關卡簽收分開記錄；補驗追加 WORK_LOG 與附錄 A，正文只更新摘要／缺口。外部前置未滿足保持阻擋，不以 fixture、跳過案例或改寫門檻結案。

W7 指定範圍、原 M2 六項逐項對照、17 站搜尋結果、guest 下載／重開及播放邊界見 [附錄 A.7](#a-w7)。有效網站帳號下載未被 guest 證據替代。

#### 5.2.5 W7.6 入口與 W8／W9 交接（2026-10-10）

**入口核對、缺口修補與單元／編譯交付完成；當時未做整體驗收，M1／M2 不補簽。** 目前依 §0.2 已恢復正式驗收；歷史證據見 [A.7.1](#a-w76)。W8／W9 消費下表既有用例，不另建播放器、下載排程或持久模型。

| 入口／用例 | 交付時接點及 owner | UI 交接限制 |
| --- | --- | --- |
| 主視窗 URL、書籤、Bilibili 動態、選集 | MainViewController 的 startSearchingUrl → 畫面自有 VideoInspectionSession → AppServices.decoder；open(result:row:) → prepareVideoUrl → Processes.prepareDanmakuFile／openWithPlayer | searchRequestID 與 inspectionID 排除晚到結果；停止解析不停止其他畫面或已啟動播放。選集傳 selectionURL、品質傳 key，不持久化列下標 |
| 關鍵詞／普通 URL 搜尋 | 每畫面呼叫 AppServices.makeBrowseSearch()；BrowseSearchService 管理查詢、來源篩選、游標及取消 | URL 直接解析、不等待 Bangumi；保留局部成功與錯誤。既有主視窗 URL 框不是已交付的新關鍵詞搜尋頁 |
| 本機 HTTP | AppServices.httpServer 注入同一 decoder；HTTPHandler 的 /video、/video/iinaurl、/video/danmakuurl → selection／resolve／prepareVideoUrl、PlaybackPreparation／PlaybackEncoder | 每請求持有原選擇；保留既有 HTTP／JSON／外掛協議，不取主視窗搜尋狀態。URL scheme 是出向 IINA；Info.plist 未註冊入向 App scheme／文件關聯，不把不存在的入口標成已遷移 |
| 開啟檔案／點播彈幕 | OpenFilesViewController.getVideo → 同一 decoder；getDanmaku → 既有本機 XML／Bilibili ID 準備；openFiles → 同一 player | 錯誤不再被吞掉後通知成功／關窗；無串流明確失敗，取消不顯示錯誤，失敗保留輸入。沒有第二套播放服務 |
| IINA／mpv、JSPlayer、直播彈幕 | Processes 使用 PlaybackPreparation／PlaybackEncoder；JSPlayerViewController 使用 AppServices.decoder；HTTP 的 DanmakuSessionManager 與 JSPlayer 的 Danmaku 實例沿用注入 decoder | 播放、下載、彈幕、WebPlayer 能力各自判斷；解析成功不外推其他能力。每播放器／連線保留自身生命週期；Torrent JSPlayer 仍不支援 |
| 元資料／作品／收藏與重開 | AppDelegate 的 WorkLibrary／FavoriteLibrary；BangumiWorkSync；既有書籤透過 makeDataManager 注入同一收藏及解析依賴 | Work／Episode／SourceItemRef 與明確關聯由持久層擁有；同名候選不得自動確認，普通連結不強造 Work |
| 日常聚合 | AppDelegate.discovery() 的 DiscoveryService；AppDelegate 協調啟動／前景／跨日刷新 | 日常 seen 基線是持久資料，不是圖片快取；排期、来源新增集、推薦及局部錯誤分開呈現 |
| 下載／設置／清理 | AppServices.downloads() 唯一 DownloadService；DownloadSourceResolver；Preferences、SiteAccounts lease、ImageCacheService | 任務 owner 不歸頁面；原帳號／guest、品質、線路及目錄快照不能被新偏好覆寫。清快取／移除帳號的拒絕原因來自服務，不由頁面預猜；完成檔沿用開啟／定位命令 |

成功、取消、局部失敗與重開的本輪覆蓋集中於 A.7.1；恢復整體驗收後仍按 §5.2.3 六條 M2 旅程補驗，尤其有效網站帳號下載／使用中移除、播放器啟動失敗的真實視窗提示及彈幕／多視窗生命週期。不新增網站帳號提供者、不把 guest 改稱帳號，也不以此交接授權 W8／W9 開工。


### 5.3 階段 C：UI 整合與切換

| 工作包 | 任務與交付 | 前置依賴 | 完成門檻 |
| --- | --- | --- | --- |
| W8 新殼、組件編排與 Skin（W8.1／W8.2／W8.4 已實作交付） | 共用組件／Layout、Skin 包與樣式、受限腳本、編輯／預覽／分享及設定入口 | W7（原 M2 缺口保留；使用者明確要求交付子包） | W8.3 外部腳本必要安全關卡仍受阻；完整 W8／W9 須 §6.2–§6.5 及產品旅程驗收，不能以局部通過代替 |
| W9 頁面整合（已實作交付） | 發現、搜尋、詳情、收藏雙欄、下載、五組設置及 Torrent；可編排組件、Skin 狀態槽與真實命令 | 使用者明確要求交付；原 M2／W8.3 缺口保留 | 本機編譯／離線回歸及隔離原生證據見 §5.3.5；§8 正式 UI 旅程與 M3 未簽收 |
| W10 全面切換與回歸（切換實作已交付） | Workspace 唯一主入口；舊 UI／冗餘分派／工程資源移除；逐站、最低系統、資料與發佈邊界檢查 | W9、W11（MT3 通過）；未簽收限制见 §5.3.6 | 第 8 節總驗收通過才簽收 M4；目前僅本機切換／離線回歸通過 |

W8 擴充拆解（W8.1／W8.2 已實作交付；W8.3 安全關卡與實作進度見下，不是另建通用插件平台）：

| 子包 | 實作範圍 | 依賴與完成條件 |
| --- | --- | --- |
| W8.1 工作區與組件（已實作交付） | 穩定組件／實例身份、能力依賴清單、版本化 Layout、容器／斷點、原生組件呈現、預設雙欄、短期狀態保存 | 移動／複製／移除所有權與 960×640 邊界已由隔離原生 host 驗證；契約與驗證限制見 §5.3.1 |
| W8.2 Skin 包與資源（已實作交付） | 樣式槽及狀態、素材覆蓋／快取、格式与資源上限、安全 ZIP 匯入／去敏匯出／替換／移除、原子套用及固定恢復入口 | 部分覆蓋、最大合法包、乾淨 profile 重匯入與失敗回滾通過；換 Skin 不換工作區，契約及證據見 §5.3.2 |
| W8.3 受限腳本（本機實作完成，外部入口未開放） | JavaScript buildLayout、獨立受限 helper、父子程序資源監控、同一 Layout 驗證／原生預覽／確認保存／撤銷 | 本機無限迴圈／記憶體成長可終止，原生 OS 權限探針及 Debug 編譯通過；最低系統及正式簽署／sandbox 關卡未通過，詳見 §5.3.3 |
| W8.4 編輯與分享體驗（已實作交付） | 拖曳／鍵盤編排、跨頁撤銷／重做、真實預覽／取消／恢復、Skin 清單、作者目錄重載、最小及完整 Skin 範例與格式文件 | W8.1–W8.3 共用模型；W8.3 外部腳本安全門檻不變。本機證據見 §5.3.4；§6.5／§8.1 完整產品旅程與 W9 逐頁驗收仍保留 |

實作依賴為 W8.1 → W8.2／W8.3 → W8.4，W9 按完成的垂直頁面整合；完整 W8／W9 不因其中一包通過而提前簽收。單元／必要編譯可在開發中執行，App／播放／真實傳輸整體驗收按 §0.2／§8 集中執行。

**M3：UI 整合完成（W8／W9）。** 基礎服務保留既有驗收責任；UI 增加呈現、互動、持久 Skin／Layout 與短期頁面狀態。M3 必須包含組件編排、實際素材換皮／分享、受限脚本及低步數設定，不可僅交固定頁面或 token 主題。發現真實契約缺口時回到對應模塊修正，不把站點判斷塞進 View；整體驗收按頁首政策集中執行。

**M4：完整重構完成（W10）。** 舊入口移除、既有能力回歸及全部驗收完成。M1／M2 可以獨立結案，但不能宣稱前端重構完成。

<a id="w81-contract"></a>
#### 5.3.1 W8.1 現行契約與交付（2026-10-10）

- 入口：Workspace 已於 W10 成為唯一主視窗；「工作區」選單（⌘⇧1）仍固定可達。設定、搜尋、開啟、活動任務與恢復命令不屬於可刪除 Layout，詳見 [§5.3.6](#w10-contract)。
- 實作：`IINA-ANI/Workspace/` 的 model／registry／validator／transactions／store／sessionState／renderer 與兩類 presenter；AppDelegate 持有整合控制器，業務服務仍由 AppServices／既有 library 持有。
- 組件契約版本均為 1：`discovery.schedule`、`discovery.updates`、`discovery.recommendations`、`search.results`、`downloads.tasks`、`favorites.works`、`favorites.links`。全部允許多實例；每個實例擁有獨立查詢與選取，收藏與任務資料仍共用業務 owner。registry 明列尺寸、父容器、能力依賴、樣式槽與設定 schema；目前組件參數 allowlist 為空。
- Layout schemaVersion=1；page／node 使用 UUID，組件另有穩定 componentID 及 contractVersion。原生 grid、horizontalStack、verticalStack、split、group、tabs 與 minimumWidth 斷點；預設發現／搜尋／收藏／下載四頁在 960 與較大視窗均保留，收藏為真正可調整的作品／連結雙欄。
- 邊界：文件 1 MiB、最多 32 頁／512 節點、深度 32、尺寸上限 8192、參數 16 KiB。解碼前檢查 JSON 巢狀深度；拒絕未知／不適用欄位、不支援版本、重複身份、同 UUID 不同組件、非法父容器／尺寸／比例／參數。
- 初次 Layout 立即保存，未修改也不會重啟換 UUID；路徑為既有 Application Support 下的 `Workspace/layout-v1.json`。驗證後原子寫入；載入壞檔顯示恢復原因且不覆寫，明確恢復／保存前備份原檔為 `.corrupt-UUID`。
- 移動保留 instanceID／query owner，複製建立跨斷點一致的新 UUID 且不複製私有查詢；目的頁在包含來源的任一斷點缺失時拒絕整筆交易。移除僅釋放該實例的訂閱／查詢，不取消共用 discovery、刪收藏或停止下載。查詢、排序、分頁、選取與捲動由 MainActor session store 暫存，不寫入分享文件；欄寬寫入 Layout。

| 能力 | 依賴與停用政策 |
| --- | --- |
| metadata／taskManagement | 核心，不可停用 |
| favorites／search | 依賴 metadata，核心不可停用 |
| playback | 依賴 taskManagement，核心不可停用 |
| schedule | 依賴 metadata，可停用；停用不呼叫排期 loader |
| favoriteUpdates | 依賴 favorites／metadata，可停用；停用不消耗更新基線 |
| recommendations | 依賴 favorites／metadata／search，可停用；停用不呼叫推薦 loader |
| downloads | 依賴 taskManagement；下載服務 actor 阻擋活動任務、入場中請求、Torrent metadata import 或尚在清理的 worker，錯誤列出受影響任務；停用後拒絕新建／恢復，活動任務入口保留 |
| danmaku | 依賴 playback；工作區不提供獨立停用，因外部播放器生命週期無法完整確認；選單說明原因，既有播放偏好不改義 |

- 驗證：Debug arm64 `xcodebuild` 成功；`Tests/run-workspace-layout.sh`、`Tests/run-w7-usecases.sh`、`Tests/run-dependency-regression.sh --unit` 通過。回歸包含初次身份保存、嚴格版本／深度、跨斷點交易、損壞恢復、能力偏好、停用 admission guard 與共享刷新取消隔離。
- 一次性 AppKit host 使用真實 Core Data 記憶體 store、實際 BrowseSearchService／DownloadService 及離線 loader：960×640 雙欄、查詢／排序／選取／捲動、欄寬保存重開、移動／複製／移除、收藏共享變更、固定搜尋結果及任務取消、移除任務面板不停止任務、巢狀原生容器／斷點／頁籤保留均通過。修正實跑發現的 constraint 啟用先於加入父 view 崩潰、split 子 view 尺寸與巢狀容器未填滿問題。
- 證據：`.build/w8.1-build.log`、`w8.1-layout-unit.log`、`w8.1-service-unit.log`、`w8.1-dependency-unit.log`、`w8.1-native-smoke.log`；bitmap 在 `.build/w8.1-evidence/`。bitmap 中部分原生按鈕／頁籤文字未顯示，固定搜尋／任務已由真實命令驗證，不據此簽收完整外觀。臨時 host 原碼、二進位與資料清除；正式 App 端到端、macOS 13.5／Intel 實機、遠端及播放器未重驗，不解除 M2，不擴大至 W8.2–W8.4／W9。

<a id="w82-contract"></a>
#### 5.3.2 W8.2 Skin 包與資源契約（2026-10-11）

- 外觀 owner 為 `SkinAppearance`，包格式／安全驗證與持久安裝分別由 `SkinModel`、`SkinPackageValidator`、`SkinArchive`、`SkinStore` 持有。原生組件經 `WorkspaceSkinPresentation` 消費同一解析與圖片快取；固定外觀選單由 `WorkspaceSkinController` 提供，不屬於作者可修改的 Layout。
- 「工作區 → 外觀」提供匯入、選擇已安裝包、跟隨系統／淺色／深色、依 Skin ID 保存字級／密度覆寫、作者原包／個人衍生包匯出、獨立套用作者佈局、移除與恢復內建外觀。後續 W8.4 已接上管理清單、無副作用預覽／取消、作者目錄重載及完整編輯流程，見 §5.3.4；不宣稱 W8／W9／M3 整體完成。
- Skin、Layout 與功能偏好獨立保存。外觀切換先準備並驗證完整候選、再原子保存選擇、最後一次通知原生 binding；不重建 query owner、不重發播放／下載。作者佈局需另行確認並經同一 WorkspaceValidator 保存為獨立副本；移除 Skin 不刪工作區。

**格式 v1。** UTF-8 JSON、ZIP 的 Stored／Deflate；檔案副檔名 `.iinaskin`。必要 `manifest.json` 與 theme 入口；components 入口可省略。manifest 的 `schemaVersion=1`、`componentContractVersion=1`；`minimumAppVersion` 按數值版本比較，目前 App 版本 `0.8.32`。metadata 包含 id、version、revision、name、author、license、supportedVariants、entryPaths、assets、assetAttributions、provenance 與可選 layout；作者／授權宣告不等於身份或權利驗證。theme 的 `system` 表示兩變體共用 token，`light`／`dark` 為變體覆蓋；是否支援變體以 manifest 明列，空覆蓋合法，不反色模擬缺少變體。

- theme token：`foreground/background/borderColor`（六／八位十六進位）、`fontFamily/fontSize`、`spacing/radius/borderWidth/density/opacity`；圖片角色引用使用 `backgroundAsset/iconAsset/placeholderAsset/decorationAsset`，與顏色欄位分離。密度為 compact／regular／comfortable，opacity 為 0–1；固定恢復／安全確認不接受 Skin 樣式。
- components 使用 `slots` 與按穩定 componentID 分組的 `overrides`；每槽有 `values` 與 `states`。公開 workCard、list、search、navigation、primaryAction、tabs、progress、background、icon、placeholder、decoration，以及 W8.1 registry 的 panel／header／row／result／task／workRow／linkRow／emptyState。狀態為 normal、hover、pressed、selected、focus、disabled、loading、error。
- 解析優先序為內建基底 → Skin 共用／明暗 token → Skin 槽與組件狀態 → 此 Skin 個人覆寫。圖片組以 normal 為必要基準；缺少自訂狀態保留原生焦點／停用等效果，不跨包混用圖像。圖片、字體與錯誤引用皆在提交前驗證；圖片按目標尺寸縮圖，共用快取含修訂、素材、縮放與尺寸，換修訂清除舊快取。
- ZIP 路徑、型別、CRC、實際輸出量與正規化後重名均驗證；拒絕絕對／越界路徑、symlink／hardlink、加密、ZIP64／分卷、巢狀壓縮、SVG／HTML／可執行檔。W8.3 安全關卡未通過前仍拒絕腳本，不因安裝 Skin 取得執行權。格式入口只能指向相對包根的允許文件，不讀遠端素材。

| 資源 | v1 上限／條件 |
| --- | --- |
| ZIP 檔大小 | 65 MiB；容納 64 MiB 有效內容及 ZIP framing |
| ZIP 項目數 | 256，含目錄項目 |
| 單一展開檔案 | 16 MiB |
| 全包實際展開資料 | 64 MiB |
| 單一 JSON 文件 | 1 MiB |
| PNG／JPEG | 每邊 ≤8192，總像素 ≤64,000,000；先檢查實際型別／尺寸，再解碼 |
| TTF／OTF | 單檔 ≤16 MiB；實際字體描述驗證、授權歸屬及 process-scope 註冊，系統字體補缺字 |
| 解碼圖片快取 | 48 MiB；按呈現尺寸／scale 共用，不逐幀讀檔 |

- 安裝在既有 Application Support 下的 `Skins/`；不可變內容修訂與原子 catalog 分離。ID／內容相同去重；同 ID 不同內容列出版本與變更檔案，明確确认後替換。內容識別包含實際素材 bytes；失敗保留原安裝與目前選擇。損壞 catalog 保留修復副本並以原生訊息告知。
- 匯出由有效模型及引用素材的允許清單重建，不遞迴分享使用者目錄；必需素材缺失即失敗。個人衍生包產生新 ID、保留作者／授權與來源，將有效外觀覆寫寫成可獨立重匯入的 Skin；選定 Layout 不含 session query／selection、帳號、收藏／歷史內容、任務或本機絕對路徑。
- 驗證：Debug arm64 未簽署 `xcodebuild` 成功；`Tests/run-skin-appearance.sh`、`Tests/run-skin-package-store.sh`、`Tests/run-workspace-layout.sh`、`Tests/run-w7-usecases.sh`、`Tests/run-dependency-regression.sh --unit` 通過。包回歸涵蓋 Stored／Deflate、路徑／重名／連結／加密／CRC／巢狀包拒絕、64 MiB／256 項最大合法包及越界、替換確認／啟用失敗回滾、catalog 恢復與乾淨 profile 衍生外觀等價。圖片實測 8192 邊長／64,000,000 像素上限可呈現、越界拒絕；真實 TTF 實測 16 MiB 可註冊／同字体修訂替換、加一 byte 拒絕。
- 一次性原生 host 實際呈現背景、placeholder、進度，驗證原生 action 僅觸發一次、selected／pressed／disabled、明暗及個人覆寫、恢復內建並保留輸入。一次性包 smoke 驗證重啟／移除、Layout bytes 不變及衍生包乾淨重匯入；修正實跑發現的 macOS `/var` 路徑正規化及衍生包組件狀態覆蓋優先序問題，後者保留永久行為回歸。
- 證據：`.build/w8.2-build.log`、`w8.2-appearance-unit.log`、`w8.2-package-unit.log`、`w8.2-layout-unit.log`、`w8.2-service-unit.log`、`w8.2-dependency-unit.log`、`w8.2-native-smoke.log`、`w8.2-package-smoke.log`、`w8.2-font-smoke.log`；原生 bitmap 為 `.build/w8.2-evidence/native-skin-dark.png`。臨時 host／二進位／資料清除。未啟動正式 App、遠端網站、播放器或真實傳輸；macOS 13.5／Intel 實機與完整產品流程未重驗，不解除 W2／M2 關卡，不擴大至 W8.3–W8.4／W9。

<a id="w83-contract"></a>
#### 5.3.3 W8.3 受限 Layout 腳本契約與安全關卡（2026-10-11）

- `Native/LayoutScript/main.swift` 使用系統 JavaScriptCore C API，提供真正的 `buildLayout(context)`。每次執行新建 helper／JS context，作者 source 獨立以 `layout.js` 評估，再呼叫函式及引擎 JSON 序列化；錯誤保留腳本行號，輸出交由 `WorkspaceLayoutCodec`／`WorkspaceValidator`，不是另一份 Layout schema。
- context 僅含 `schemaVersion`、`componentContractVersion`、`components` 能力描述及使用者明確給定的 `configuration`。組件描述包含穩定 `id`、版本、預設／最小尺寸、允許容器、多實例與參數鍵；不傳現有工作區、帳號、收藏、下載、Preferences 或 session。組件 JSON 的 `componentID` 是字串；斷點沿用 Layout v1 的交替鍵／值陣列編碼。
- helper 在處理輸入前關閉繼承的額外 FD、禁止 core dump、設 `JSC_useJIT=false`，安裝 deny-default Seatbelt profile。僅允許引擎所需系統 framework／runtime／ICU 讀取與 sysctl-read，沒有作者可呼叫的 native bridge、檔案、網路、程序或 Keychain API。初始化或記憶體監控失敗即退出；不退回主程序執行。

| 資源 | 限制與處理 |
| --- | --- |
| JavaScript source | UTF-8 128 KiB |
| stdin JSON（source＋context） | 256 KiB |
| stdout JSON | 實際 UTF-8 1 MiB，父程序同步限制讀取量 |
| stderr | helper 錯誤文字有界；父程序上限 8 KiB |
| 牆鐘 | 2 秒；父程序 SIGKILL 並 wait/reap，子程序另設 watchdog；取消同樣終止／回收 |
| 記憶體 | 128 MiB physical footprint 閾值，父子程序每約 5 ms 檢查並終止；取樣可有瞬間超量，不冒稱 kernel allocation hard cap |
| Layout 結構 | 沿用 v1 的 32 層、512 節點、32 頁／variant、16 KiB 參數與 1 MiB 文件限制 |

- 本機證據：`Native/LayoutScript/security-regression.sh` 對 hardened-runtime ad-hoc 簽署 helper 驗證真正 JS、無限迴圈／序列化 getter 逾時、配置記憶體成長先於 deadline 終止、行號錯誤、最大合法 ASCII／多位元 UTF-8 輸出及越界輸入。原生測試編譯旗標下使用相同 sandbox，以成功的未受限讀檔／socket／Keychain Mach lookup 作控制；受限後確認檔案讀写、localhost connect、fork／exec 返回 EPERM／EACCES，Keychain Mach lookup 返回 BOOTSTRAP_NOT_PRIVILEGED。探針不編入正式 helper，不把缺少 JS globals 當作 OS 隔離證據。
- `Tests/run-workspace-layout-script.sh` 驗證函式／迴圈／條件生成雙收藏巢狀與 960 斷點 Layout、同一 store 保存重讀、未知欄位／source 上限／例外／取消拒絕，失敗後原檔不變且下一次可獨立執行。日誌：`.build/w8.3-security.log`、`.build/w8.3-script-unit.log`、`.build/w8.3-layout-unit.log`。
- 原生接線：每次明確選擇 `.js` 與可選 JSON 配置後才執行；來源有界讀取，非 UTF-8／超限拒絕。生成前保存 baseline，取消或較新 generation 取代舊工作；先檢閱差異，再於同一原生 renderer 的隔離預覽視窗瀏覽頁面／容器。真實組件控制項以 preview-only 模式呈現，不讀服務或寫 session／業務資料。只有預覽內明確套用且 baseline 未變才能原子保存，整筆進入 window UndoManager；Skin 安裝、App 啟動或縮放不會呼叫 runner。
- 工程：App build phase 將 universal helper 放入 `Contents/Helpers/LayoutScriptHelper`，簽署建置時先按同一 identity 簽 helper；未簽署 Debug `xcodebuild` 成功（`.build/w8.3-build.log`）。實際執行該包內 arm64 helper 與 Rosetta x86_64 slice，均由 JS 迴圈產生兩頁 JSON（`.build/w8.3-packaged-helper-smoke.log`、`.build/w8.3-rosetta-smoke.log`），不是只檢查架構標頭。既有 Layout、Skin appearance／package、W7 usecases、dependency --unit 通過；不啟動正式 AppDelegate、遠端網站、播放器或傳輸。
- 原生實跑：隔離 AppKit host 透過包內 helper 執行真正 `buildLayout(context)`，產生雙收藏 Layout。1280px 並排／1000px 堆疊斷點、取消不保存、baseline 過期拒絕、明確套用與重讀、單筆具名 undo（無殘留 action）、redo／再次 undo 通過（`.build/w8.3-native-smoke.log`）。以 `screencapture` 擷取實際 modal NSWindow，已檢視 `.build/w8.3-native-window-wide.png`、`.build/w8.3-native-window-narrow.png`；套用／取消文字、安全提示與原生組件可見。一次性 host／執行檔／隔離資料已刪除。外部選檔入口受安全 gate 關閉，未宣稱正式 App 匯入端到端驗收。
- **尚未解除的必要關卡**：只有目前 arm64 系統執行證據；universal arm64／x86_64 helper 的 13.5 deployment target 不是 macOS 13.5 或 Intel 實機測試。hardened ad-hoc 簽署不是本 fork 正式 Developer ID／公證或 App Sandbox entitlement 組合。`WorkspaceLayoutScriptRunner.externalImportEnabled` 保持 false；Skin ZIP 持續拒絕 `.js`，安裝／啟動／縮放均不執行作者碼。取得最低系統與正式發佈組合實測之前，不宣稱 W8.3 全項完成或開放外部腳本。

<a id="w84-contract"></a>
#### 5.3.4 W8.4 編輯、預覽與分享契約（2026-10-11）

**入口與所有權。** 工作區工具列「編輯佈局」開啟原生編排樹及服務隔離的真實工作區預覽；固定「工作區 → 外觀 → Skin 管理…」提供已安裝清單。`WorkspaceLayoutEditor` 只持有值型別草稿，`WorkspaceLayoutEditorController` 使用 Registry 與同一 validator；`WorkspaceWindowController` 持有已保存工作區及跨整份套用的 UndoManager。Skin 由原有 `SkinStore`／`SkinAppearance` 持有，不新增業務服務 owner。

- 日常模式不顯示編排把手。編輯樹支援拖曳跨頁／容器、鍵盤上移／下移／移至、32 pt 吸附尺寸、split 比例、增刪／折疊組件，以及頁面新增／更名／刪除／首頁／導覽排序與隱藏。grid、horizontalStack、verticalStack、split、group、tabs 可新增／轉換；各宽度斷點可獨立編輯。無效選取的操作停用，非法尺寸、循環目的地等在提交前拒絕。
- 一次 drop 或預覽 split 分隔線手勢是一筆草稿交易。草稿跨頁撤銷／重做不寫磁碟；取消／關閉不覆寫已保存 Layout，結束編輯才驗證與原子保存。再次進入會聚焦既有草稿；編輯期間外部操作改變已保存工作區時，拒絕過期草稿覆蓋。保存整份工作區仍可撤銷／重做，穩定 instanceID 與短期查詢狀態不交換。
- Layout v1 增加可省略的 `homePageID`、`hiddenPageIDs`、`collapsedInstanceIDs`；舊文件讀取為無首頁覆寫／空集合。驗證引用身份，刪除時清理無效呈現 metadata。折疊／移除面板不刪收藏、不停止獨立下載；固定搜尋、設定、活動任務及各自恢復入口不受 Layout 控制。
- Skin 選檔／開檔／管理頁拖入後，先在自有臨時目錄建立經驗證且 digest 固定的快照，再直接開啟隔離原生預覽。可信預覽頂部顯示版本／作者／授權及預設不勾選的「外觀＋作者 Layout」；切換立即在同一原生預覽呈現，純外觀不多加確認。取消不安裝、不保存選擇／覆寫／Layout。相同 ID 不同內容另列檔案差異並明確批准；安裝時重新核對快照與批准 digest。
- catalog 安裝／選擇原子提交後才啟用作者 Layout，啟用失敗回滾 catalog；舊 revision 成功前保留，回滾本身失敗回報兩個錯誤並保留修訂供恢復，不假稱舊狀態已恢復。預覽結束比對 Layout（含尚未存在）、已選 Skin digest、外觀 revision／scheme 與目標個人覆寫，拒絕過期候選。
- 管理頁顯示版本／作者／授權、移除、原包／衍生包匯出與恢復；內建外觀沒有第三方包的操作禁用。作者目錄明確「重新載入並預覽」，每次重新驗證不可變快照；檔案／欄位錯誤可定位，不監視或自動提交。衍生分享明選不帶／目前／作者 Layout，生成新 ID、保留來源與授權；共用 `WorkspaceLayoutCodec.sanitizedForSharing` 清除所有變體的私人組件 parameters。
- `Examples/Skins/minimal` 為最小 token 覆蓋，`full` 為明暗素材、19 槽／8 狀態及七組件覆蓋。26 個 PNG 為原創 CC0 幾何素材；使用系統字體，不再散布系統字體。`bash Examples/Skins/package.sh <新輸出目錄>` 使用生產 validator／ZIP 生成兩份 `.iinaskin`；完整格式、上限、公開槽及作者操作見 [Examples/Skins/README.md](../../Examples/Skins/README.md)。

**實際驗證。** 未簽署 arm64 Debug `xcodebuild` 成功；Layout、Skin package/store、Skin appearance、Layout script、W7 usecases 與 dependency `--unit` 通過。回歸涵蓋全部容器、非法移動／尺寸原子拒絕、跨頁撤銷、斷點隔離、重啟、作者重載快照、取消、替換／啟用失敗回滾、二次回滾失敗明示及衍生去敏。兩份範例實際打包、匯入／去重、原包匯出至乾淨 profile 再匯入後模型／素材 bytes 相同，衍生包身份／授權與基礎／斷點參數去敏通過。

隔離 AppKit host 實際操作鼠標跨頁拖曳、撤銷／重做、鍵盤移至、草稿取消、保存／重讀及工作區 UndoManager；實際 NSWindow 預覽取消／套用兩份 Skin、明確作者 Layout、管理頁關閉重開、恢復 Skin 不刪作者 Layout 通過，業務命令／服務呼叫計數為零。實跑修正編輯说明裁切與 Skin metadata 被標題列遮住，後者移至可信內容區。操作成本：編輯入口 → 手勢 → 結束保存；Skin 選檔 → 直接預覽 → 套用，純外觀不額外詢問；替換同 ID 保留必要差異確認。這是局部流程，不把 W9 設定搜尋或播放流程計為已驗收。

證據：`.build/w8.4-build.log`、`w8.4-layout-unit.log`、`w8.4-package-unit.log`、`w8.4-appearance-unit.log`、`w8.4-script-unit.log`、`w8.4-service-unit.log`、`w8.4-dependency-unit.log`、`w8.4-examples.log`、`w8.4-native-smoke.log`；實際視窗 `w8.4-editor-narrow.png`、`w8.4-drag-redo.png`、`w8.4-full-applied-preview.png`、`w8.4-author-layout-preview.png`、`w8.4-skin-manager.png`。臨時 host／執行檔／profile 移除，保留證據與作者範例。

**未擴大簽收。** 未啟動正式 AppDelegate、遠端站點、播放器或真實傳輸；Finder 系統檔案關聯端到端、VoiceOver 全旅程、macOS 13.5、Intel 實機、正式簽署／公證仍待產品验收。W8.3 `externalImportEnabled` 保持 false、Skin ZIP 拒絕 `.js`；不解除 W2／M2／M3／MT3，不把 W9／W10／W11.4 記為完成。

<a id="w9-contract"></a>
#### 5.3.5 W9 頁面整合交付（2026-10-11）

**實作已交付；集中產品验收未簽收。** 依本次「完成 w9」要求整合全部頁面及 W11.4 UI，不把既有 M2、W8.3 安全門檻或 MT3 改記為通過，W10 全面切換仍獨立執行。

- 預設 184 pt 側欄為發現／搜尋／收藏／下載，設定置底；詳情與 Torrent 是內容路由，非必要側欄入口。頂部全域搜尋常駐，固定選單保留搜尋、開啟網址、Torrent 檔案、活動任務、設定與恢復。自訂 Layout 隱藏／刪除入口時開啟內建恢復頁，不覆寫作者 Layout；返回保留原實例的查詢、分頁及選取。
- 發現使用 DiscoveryService 的排期、收藏更新與推薦分區，顯示日期、來源、更新證據與推薦原因；分區錯誤不混成空內容，跨日／重新啟用 App 刷新。搜尋直接使用 BrowseSearchService，支援分類、啟用來源、獨立分頁、取消及過期結果拒絕；作品／影片結果攜帶精確 typed destination，不按名稱猜關聯。
- 詳情新增 `detail.media` 組件：封面／缺圖狀態、作品 metadata／更新時間、全部集數類型、來源／分 P／品質／線路／帳號明選、收藏、手動 Bangumi 關聯／解除、來源新增／移除及明確集數 mapping。播放與下載共享同一 PlayableSelection；JSPlayer 初始選擇、重新載入與彈幕請求固定同一帳號及集數上下文，播放視窗由 AppServices 持有，不被面板移除關閉。
- 收藏雙欄保留獨立查詢／排序／手動順序，開啟作品或原始連結；可編輯作品名稱／別名及連結名稱／網址，既有失效 URL 可只改名稱。移除收藏僅改 membership，不刪 Work／Episode／來源／下載。搜尋與收藏以直式作品封面、橫式影片縮圖及明確缺圖標記呈現。列表「組件設定」只改本實例密度，不改 Skin 或業務狀態，也不寫入分享文件。
- 下載沿用唯一 DownloadService：進度、速度、ETA、分段／失敗原因、暫停／恢復／取消；完成檔使用正式播放器開啟、Finder 顯示、只刪記錄或確認刪除檔案的既有命令。
- 設定新增 `settings.preferences`：外觀與工作區、來源與帳號、播放與彈幕、下載與儲存、關於與進階。搜尋同義詞定位並聚焦真實控制項，非同步帳號刷新保留焦點；偏好即改即保存。來源 reload、帳號登入／更名／刪除／預設與使用 lease、播放器／外掛、目錄／並發／快取、Skin／Layout 均連接既有 owner。舊 WindowManger 與四個 SwiftUI 設定頁移除；共用登入容器、帳號注入與外掛安裝流程保留，未移除 W10 的舊主視窗。
- Torrent 新增 `torrent.import`：magnet／本機 .torrent、首次 P2P 上傳同意、有效上限、metadata 可取消、非首檔精確 index／path／size 明選，分開建立播放 reader 與下載；精確收藏／作品集數關聯重開仍沿用既有身份。設定可調整活動上限或停止 P2P，較低的既有任務上限不被放寬。停止只等待 Torrent admission 排空，不被無關 HTTP 任務阻塞；停止保留已下載檔案及非 Torrent 任務。
- 三個新組件沿用同一 Registry／Layout v1／Skin 槽，不新增服務或任務頁。舊 Layout／Skin 仍可載入；預覽停用業務命令，移除實例只取消其查詢／訂閱／未提交 metadata，已提交播放及下載不受影響。明暗 Skin 同步 AppKit 控制項的原生 appearance，避免淺色背景仍使用深色控制項文字。

**本機證據與限制。** 未簽署 arm64 Debug 編譯；WorkspaceLayout、WorkLibrary、設定搜尋、W7 usecases、dependency --unit 與 SkinAppearance 回歸。隔離 AppKit host 使用記憶體 Core Data、實際服務命令及離線載入器，操作搜尋分頁／typed 詳情／返回、雙欄與密度隔離、真實 DownloadService 暫停／取消、設定定位及 Preferences 重讀，檢視 1280×800／960×640 與明暗介面。這些不是遠端服務或正式產品旅程證據。

證據保留於 `.build/w9-build.log`、`w9-layout-unit.log`、`w9-work-library.log`、`w9-settings-unit.log`、`w9-service-unit.log`、`w9-dependency-unit.log`、`w9-skin-unit.log`、`w9-native-smoke.log` 及 `w9-*.png`。系統 WindowServer 截圖回報無法建立影像；保存並檢視的是實際 NSView bitmap，不能宣稱正式視窗合成／所有原生材質已視覺驗收。未啟動正式 AppDelegate、真實網站、播放器或 P2P；Finder 開檔端到端、VoiceOver 全旅程、macOS 13.5、Intel 實機、正式簽署／公證與 §8 集中旅程仍待驗收。W8.3 外部腳本入口維持關閉。

<a id="w10-contract"></a>
#### 5.3.6 W10 全面切換實作與驗收邊界（2026-10-11）

**切換實作已交付；W10／M4 總驗收受阻，未標為已驗收。** 本次完成可在目前環境交付的主入口、舊 UI 清理、能力遷移及本機回歸；保留 §8 全部驗收要求，不將離線或隔離 host 證據代替逐站、帳號、正式產品與發佈驗收。

- `AppDelegate.main` 明確建立／持有 delegate，啟動顯示 Workspace；Dock 重開喚回同一視窗，關閉只釋放畫面查詢／訂閱，重開重建呈現。`MainMenu` 改為程式建立原生選單，文字編輯走 responder chain；固定搜尋／設定／關注動態／任務／開啟與恢復不依赖作者 Layout。⌘O 保留本機影片＋XML／B 站 ID 輔助視窗；既有 Skin／Torrent 檔案關聯及 JSPlayer 不移除。
- 移除 Main／Preferences Storyboard、舊主視窗／側欄／選集／設定 controller、xib、只屬舊 UI 的通知／formatter／本地化表及工程引用。JSPlayer 共用 row 移到播放器目錄；LivePlayer 移至 Preferences；仍使用的外掛安裝文案遷入 Localizable。Sparkle、Settings、SDWebImageSwiftUI 三個無剩餘使用者的依賴與 lock pin 移除，其他資源／模型／授權保留。
- 新增 `discovery.followed`（Layout／組件契約仍為 v1）：沿用 BilibiliDynamicManger，初始／新／歷史分頁、開啟／複製／原網頁與明確錯誤；弱 delegate 與取消阻止卸載面板後更新。舊自訂 Layout 可從固定入口開啟恢復頁，不被覆寫。
- 收藏連結保留 DataManager 的直播狀態／來源篩選、定時與手動刷新、原狀態色；作品／連結支援原順序拖曳，有查詢／篩選或非手動排序時不允許拖曳。查詢、篩選與密度按 instance 分離。刷新由面板持有可取消工作；刪面板不留下無 owner 的刷新。收藏頁提供原 context undo，文字欄與 Layout 使用各自 responder／undo owner。
- 詳情保留既有直接解析／目錄選擇、自動開啟與 Option 抑制、外部／JSPlayer 選擇及 Huya 預熱；外掛缺失只阻擋實際需要外掛的 IINA 彈幕路徑，不擋 normal IINA／mpv／停用彈幕。設定补回四種狀態色與既有瀏覽器彈幕測試入口。
- 發佈安全：移除 Sparkle 啟動／檢查更新、上游 feed／公鑰及舊 0.7 公告。Bundle ID、資料目錄及偏好鍵不遷移；不能以停用更新宣稱可獨立發佈。

**已執行證據。** macOS 27.0.1 arm64／Xcode 27.0 未簽署 Debug build、plist／pbxproj lint、dependency --unit、W7 usecases、W5 收藏／舊庫遷移與 WorkspaceLayout 回歸通過。遷移回歸刻意注入 failed-save，日誌的 SQLite rollback／optimistic-lock 錯誤屬其失敗保護情境，最後各情境 PASS。原生隔離 host 使用正式 Debug dylib 與獨立 home／Bundle ID，驗證收藏 live 篩選、關注列表順序／錯誤／卸載後拒絕更新、設定顏色保存／固定恢復頁不覆寫自訂 Layout、⌘O 真實 storyboard 載入、關窗重開只保留一個 Workspace、未支援檔案拒絕及 magnet 進 Torrent 頁。固定工具列深色白底／文字不可見問題在同一原生煙霧中修復。

證據：`.build/w10-build.log`、`w10-final-build.log`、`w10-dependency-unit.log`、`w10-usecases-unit.log`、`w10-favorites-migration.log`、`w10-layout-unit.log`、`w10-native-smoke.log` 與 `w10-*.png`。1280×800／960×640 的圖片為實際 NSView bitmap；不冒充完整 WindowServer 合成、VoiceOver 或系統檔案關聯驗收。

| 尚未簽收 | 缺少的證據／前提 |
| --- | --- |
| 正式產品集中旅程與逐站回歸 | W10 交付時未執行正式產品旅程；現已恢復，逐項結果與尚缺證據見 [R7 集中結果／受阻報告](#r7-acceptance)，不將局部通過當作 §8 全流程簽收 |
| W2／原 M2／M3／MT3 | 真實雙帳號／重新授權、指定帳號下載、產品入口 Torrent 全鏈等既有門檻未由本輪替代 |
| W8.3／最低系統 | 缺 macOS 13.5、Intel 實機與正式簽署／App Sandbox 組合；外部腳本匯入保持 false |
| 獨立發佈 | 缺 fork 身分／資料共存決策、Developer ID 發佈與公證；本機僅見 Apple Development identity，未當作正式發佈證據 |


### 5.4 新增工作流：W11 Torrent 支援（W11.1–W11.3、MT1／MT2 已驗收）

W11 是新增編號，不代表必須等 W10 才開始。W11.1 → W11.2 → W11.3 可在既有基礎服務上先做，毋須新 UI；W11.4 與 W9 整合，仍須原 M2 通過。保留 W0–W10／M1–M4 編號與既有簽收，不重開已完成工作包。

| 工作包 | 任務與交付 | 前置依賴 | 完成門檻 |
| --- | --- | --- | --- |
| W11.1 原生核心與橋接（已驗收） | 鎖定 libtorrent-rasterbar 2.1.2、依賴與建置入口；薄橋接、session／alert 所有權及關閉 | W1 契約、W2 已交付的偏好／owned-cache 基礎 | App 已連結並實際驅動 2.1.2；自建合法資料的 loopback 兩 peer 三輪真實下載、精確 bytes、重複啟停／取消通過；架構、dylib 與 deployment target 證據見附錄 A.8，不以 Python wheel 代驗 |
| W11.2 任務、選檔與恢復（已驗收） | magnet／本機 torrent、metadata／精確選檔、DownloadService backend、共享 transfer、resume／目錄／上傳政策 | W11.1、W3 共用來源入口、W5 收藏、W6 任務服務 | v1／v2-only／hybrid；多檔選非首個影片；暫停／取消、正常與強制退出重開、損壞 resume 重校驗、無 peer／磁碟不足／路徑與刪除隔離；完成檔雜湊正確，既有 HTTP／HLS 不回歸；實際證據見附錄 A.9 |
| W11.3 Range 串流與播放器（已驗收） | NIO 路由、piece deadline／缺塊等待、有界緩衝、reader／URL 授權生命週期 | W11.2、既有 Processes／外部播放器入口 | HTTP 回應範圍與 bytes 正確；限速 peer 的未完成影片由 IINA／mpv 實際載入、seek 尚未下載的中段／尾段後繼續播放；已完成塊、斷線／取消、雙 reader／獨立下載隔離通過；證據見附錄 A.10 |
| W11.4 產品整合與相容驗收（UI 已實作，驗收未完成） | 已與 W9 共用匯入／選檔、詳情、下載／設置頁；精確收藏／作品關聯 | W11.3；本次依使用者要求與 W9 同步整合，不解除原 M2 | 正式入口 §8.1 Torrent 旅程、macOS 13.5／架構、依賴授權／簽署及 MT3 仍待集中驗收 |

**MT1：Torrent 任務核心完成（W11.1／W11.2，2026-10-09 已通過）。** 原生核心、精確身份及真實下載／恢復通過，不等於可串流播放。

**MT2：Torrent 串流閉環完成（W11.3，2026-10-09 已通過）。** 外部播放器實際缺塊 seek、共享生命週期與安全邊界通過。MT2 不是原 M2 的替代，不解除有效網站帳號驗收要求。

**MT3：Torrent 產品驗收完成（W11.4）。** 新增目標全鏈與最低系統／打包通過；W9 的 Torrent UI 項須交付，W10／M4 總結案須包含 MT3。非 Torrent 的 W8／W9 工作仍按原依賴推進，不把 W11 核心當作主題開發前置。

歷史證據：[W11.1 核心／橋接](#a-w111)、[W11.2／MT1 任務／恢復](#a-w112)、[W11.3／MT2 Range／播放器](#a-w113)。

恢復驗收後使用自建或明確授權的媒體／多檔 torrent、受控 loopback peers 驗證；metadata、private torrent 與發現政策另用受控環境。不使用未授權公網內容或現用私人資料；原碼、建置、native、HTTP、播放器及發佈證據分開記錄。

<a id="repair-plan"></a>
### 5.5 正式 App 問題修復計劃（2026-10-11）

**狀態：R0–R6 已完成；[R7 集中結果／受阻報告](#r7-acceptance)已交付。** 使用者回報視為已知問題，不要求再次證明。R0 故障基線及 R1–R6 歷史證據保留，R7 各矩陣／旅程有結果，不代表全部通過。

本輪沿用 W9／W10 及 M3／M4，不新增另一套重構里程碑。先恢復可用性，再收斂產品語義，最後接通尋源實播；只使用既有來源能力，不擴大網站、下載或 P2P 範圍。

| 工作包／優先級 | 工作與既有落點 | 前置 | 完成條件 |
| --- | --- | --- | --- |
| R0 正式驗收基線／P0（已完成） | 建置本份來源，走 AppDelegate 冷啟動；核對產物路徑、profile、既有行程與埠；記錄搜尋／空白問題的操作序列、截圖及錯誤；[證據](#r0-baseline) | 無 | 正式視窗已操作；原 profile 380 檔 SHA-256 未變；故障狀態有定位證據，未用 host 代替 |
| R1 搜尋修復／P0（已完成） | WorkspaceServicePanelController、BrowseSearchService；已核對 WorkspaceRenderer 的正式輸入提交及既有詳情 action，無需改 renderer | R0 | 關鍵詞、URL、來源篩選、分頁、取消、返回、空結果與錯誤狀態及普通 URL 真實 mpv 播放已驗證；[證據與限制](#r1-search) |
| R2 重複導航空白／P0（已完成） | WorkspaceRenderer 與各面板 attach／detach；沿用 WorkspaceApplicationController 的單一 window owner 及 WorkspaceSessionState | R0、R1 | 同頁連點不重建；跨頁連點不新增重複面板，主內容填滿；返回及實際關窗／固定選單重開保留結果與畫面狀態；[證據與限制](#r2-navigation) |
| R3 類型隔離／P1（已完成） | 搜尋快照／結果、詳情路由、Bangumi／來源分類與既有 Work／Episode／SourceLink；版本化副本遷移 | R1、R2 | 番劇／一般影片／直播／未知在資料、路由與命令層隔離；正式 App 分區、命令拒絕及分類修正後退出重啟已驗證；[證據與限制](#r3-classification) |
| R4 固定詳情格式／P1（已完成） | WorkspaceDetailController、既有 Registry／Skin 及詳情路由 | R3 | 番劇／影片／直播／未知固定模板，搜尋／網址／收藏／推薦入口一致；兩種尺寸、明暗與自訂 Skin 正式操作通過；[證據與限制](#r4-detail) |
| R5 設定層級／P1（已完成） | WorkspaceSettingsController、WorkspaceRenderer；沿用 WorkspaceSettingsSearch 與 WorkspaceApplicationController 的路由／服務 | R2；可與 R3／R4 獨立實作 | 五分類常駐、分類 → 設定項兩層、搜尋直達及單一設定 owner；正式 App 與自訂佈局固定入口已操作；[證據與限制](#r5-settings) |
| R6 番劇自動尋源與選單／P1（已完成） | AnimeSourceService、SourceRegistry／SourceSearch／VideoDecoder 的既有能力、作品來源／集數映射、WorkspaceDetailController、Processes | R3、R4；使用 R1 已修復的搜尋能力 | guest 有界尋源、可信精確映射自動播放、候選確認與單次提交；正式 App 換源、取消、缺集拒播、保存重開及 mpv 番劇實播；[證據與限制](#r6-anime) |
| R7 集中驗收／關卡（結果報告已交付） | 正式搜尋／詳情／尋源／播放及設定／返回／重啟；[逐項結果](#r7-acceptance) | R1–R6 | 七列矩陣及十四旅程有結果；失敗／缺環境受阻，M2／M3／MT3／M4／W8.3 不代簽 |

<a id="r0-baseline"></a>
#### 5.5.0 R0 正式 App 基線（2026-10-11 已完成）

- **建置／入口**：README 的 Debug `xcodebuild` 指令另加 `PRODUCT_BUNDLE_IDENTIFIER=org.iina-ani.r0-baseline`，`BUILD SUCCEEDED`。本次來源產物為 `.build/xcode/Build/Products/Debug/IINA+.app`，版本 0.8.32／build 1791706225；主執行檔 SHA-256 `2341d14d7bd60e14363113ea9d86801d95de54ae7ee7f3a89c8c1bacf109aba7`。直接執行 App 主程式，日誌記錄 `AppDelegate.applicationDidFinishLaunching`，不是隔離 host。未改 App 原始碼／工程／測試。
- **資料／行程**：`CFFIXED_USER_HOME` 與 `HOME` 指向 `.build/r0/home`，獨立 Bundle ID 隔離偏好、HTTP storage 與 Keychain service；沒有複製或清除私人帳號、Cookie、收藏。App log／lsof 確認 Core Data 位於隔離 home 的 `Library/Application Support/IINA+/DataModel.sqlite`，任務／快取與 HTTP storage 也位於隔離 home。原 profile 七個資料根共 380 檔，驗收前後 SHA-256 相同。既有 IINA PID 76128 保留，啟動前沒有 IINA+；沒有觸發播放或 P2P。
- **埠**：啟動前 19080／19280 無 listener；雖傳入 `-dmPort 19280`，正式服務實際綁定 `127.0.0.1:19080`，以日誌及 lsof 為準，不把參數當作綁定成功。此次沒有埠衝突。

| 操作序列／觀察 | 定位證據（均位於 `.build/r0/evidence/`） | R1／R2 接手邊界 |
| --- | --- | --- |
| 冷啟動 → 發現 → 側欄搜尋 → 全域框輸入「葬送的芙莉蓮」並 Return；面板收到同查詢並完成 47 筆 | `cold-launch.png`、`search-empty.png`、`global-search-submitted.ax.txt`、`search-settled.ax.txt`／`.png` | 本情境輸入提交與服務回應可達，不否定其他搜尋失效 |
| 搜尋結果含 eacg／forest／kanba／youknow HTTP 403，fengche／hanime1 格式不符；錯誤控制項只呈現前三行，debugger 可讀到完整六站錯誤 | `search-repeat20.png`／`.ax.txt`、下列 debugger 狀態 | 區分遠端拒絕／解析格式／錯誤呈現；不把有結果當成全站正常 |
| 面板輸入 `https://bangumi.tv/subject/390200` → Search，0 筆並顯示 `IINA_.VideoGetError error 8`，沒有進入 Bangumi 詳情 | `bangumi-url-error.png`／`.ax.txt` | `WorkspaceServicePanelController.search` → `BrowseSearchService.performSearch` 的 URL／影片解析邊界；根因修復留給 R1 |
| 1280×800 與 960×640 內容尺寸各同頁點擊 20 次；另搜尋 ↔ 收藏交替 20 輪；每次 AXPress 均回 0 | `search-repeat20`、`narrow-repeat20`、`alternate20` 的 `.actions.txt`／`.ax.txt`／`.png` | 寬視窗搜尋外 scroll 只有 760×640，右側／底部留下空白；窄視窗外 scroll 為 776×599 且內表最低高度超出外區。未觀察到空白隨點擊數持續增長，仍保留使用者缺陷回報 |
| ⌘W 關窗 → 工作區固定命令 ⌘⇧1 重開；原 URL 查詢／錯誤仍可見 | `reopened.png`／`.ax.txt` | 重開後空白仍在；不宣稱返回、所有頁面或 controller／約束釋放已驗收 |

Debugger 在 `WorkspaceRenderer.swift:610`（`host.layoutSubtreeIfNeeded()` **執行前**）記錄：host 960×599、host 下 1 個 shell、service owners 5／product owners 0／cached containers 1／navigation history 41；`search.results` 為 attached=true、generation=1、query=葬送的芙莉蓮、rows=47，完整錯誤為上述六站。此處新 shell frame 尚為零屬佈局前狀態，不能拿來證明零尺寸根因，也不能由單次 owner 數量推斷無洩漏。`renderPages`／`renderNode` 的重掛及容器 sizing 是 R2 調查落點，尚未確定累積空白根因。

**驗收邊界**：R0 只簽收本份來源建置、正式視窗操作、原資料保護與可定位故障基線；沒有完成搜尋／導航修復，未跑 R7 全矩陣、真實播放／彈幕／下載、有效帳號或最低系統。原 M2／M3／MT3／M4 與 W8.3 安全門檻不變。正式「結束 IINA+」選單退出 exit 0；原 IINA 保留。一次性 AX／雜湊工具清除，隔離 profile 與去敏證據保留供 R1／R2 對照；`app.log` 中 `__lldb_expr` nil unwrap 是除錯表達式錯誤，不是自發 App crash，限制見 `debugger.json`。

<a id="r1-search"></a>
#### 5.5.0.1 R1 搜尋修復（2026-10-11 已完成）

- **修復**：Bangumi 三個既有 host（bangumi.tv／bgm.tv／chii.in）的 HTTP(S) subject 正整數網址改走精確作品路由，不送影片解碼器，不依賴關鍵詞搜尋／元資料可用。其他 URL 保留既有影片選擇；沒有搜尋能力的來源仍可輸入 URL。
- **面板**：來源選單只列啟用且宣告 search 的 registry 項目；顯示分類決定錯誤／分頁可用性，不因隱藏分組尚有游標而提供無結果的更多按鈕。新增搜尋取消，空輸入／新查詢清除舊快照與更多狀態；分頁保留已有列並顯示載入，替換／取消／detach 經畫面 generation 及底層 task cancellation 拒絕晚到回應。新查詢回到列表頂部；全部來源錯誤可見，不再截為三行。未修改 renderer 容器幾何、Core Data 或播放器。
- **建置／入口／資料**：本份來源 Debug BUILD SUCCEEDED，Bundle ID org.iina-ani.r1-search，正式 AppDelegate／Workspace；產物 .build/xcode/Build/Products/Debug/IINA+.app，隔離 home .build/r1/home。主程式 SHA-256 2341d14d7bd60e14363113ea9d86801d95de54ae7ee7f3a89c8c1bacf109aba7（Debug launcher 不因源碼改動而變）；實作 dylib SHA-256 2992b2f942895733a9665302de3a5ceab2cf154033eee2d2717f2501d07d6a30。原 profile 380 檔驗收前後 SHA-256 完全相同，沒有複製帳號／Cookie。播放器使用隔離偏好的 mpv 與 guest；enableDanmaku=NO，不變更原 IINA。

| 正式操作／結果 | 證據（.build/r1/evidence/） |
| --- | --- |
| 全域「葬送的芙莉蓮」Return → 47 筆，Bangumi／來源列分開；六站局部錯誤完整可見 | final-keyword.ax.txt／.png |
| 來源影片＋bilibili → 20 筆；More Results → 40 筆，查詢／來源／分类保持；載入中保留前頁 | final-bilibili-page1.ax.txt／.png、final-pagination-loading.ax.txt、final-bilibili-page2.ax.txt |
| 列表滾動 0.4 → 收藏 → 返回：40 筆、同查詢／篩選；scrollbar 0.4 → 0.3999406 | final-before-return.ax.txt、final-after-return.ax.txt／.png |
| Cancel → 已取消／0 列；等待後仍無晚到結果；Naruto 立即換 bgm.tv subject/390200/ → 只有精確作品引用 | final-cancelled.ax.txt、final-cancelled-late.ax.txt、final-replacement-url.ax.txt |
| 分頁載入保持 20 筆，Cancel 後仍 20 筆且 More Results 可再用／Cancel 停用 | final-more-cancel-loading.ax.txt、final-more-cancelled.ax.txt |
| Bangumi subject/390200 → 雙擊結果 → 正確 ID 的真實作品詳情／元資料 | final-bangumi-detail.ax.txt／.png；與 R0 bangumi-url-error 對照 |
| girigiri／「葬送的芙莉蓮」得到成功空結果；More Results 停用；不支援 URL 顯示可操作錯誤；空輸入不能沿用舊分頁 | final-empty-results.ax.txt／.png、final-unsupported-url.ax.txt／.png、final-empty-input.ax.txt |
| 無 keyword search 的 bilibili-live URL 仍取得一筆直接解析結果；普通 BV 網址不依賴 Bangumi／目前來源篩選 | final-nonsearchable-source-url.ax.txt、final-media-url.ax.txt |
| BV1xx411c7mD → 詳情／分 P／清晰 480P → 正式播放按鈕 → 真實 mpv 視窗，連續截圖顯示不同解碼畫面 | final-media-detail.ax.txt／.png、final-play-command.ax.txt／.png、mpv-playing.ax.txt／.png、mpv-osd.png、mpv-clock.png |
| ⌘W／⌘⇧1 保留面板 query／分類／來源；結果須重新提交，不代簽 R2 的重開完整狀態 | final-reopened.ax.txt／.png |

**回歸**：Tests/run-w7-usecases.sh 全部通過。BrowseSearchRegression 增加三 host／scheme／路徑／ID 邊界、URL 不分頁、搜尋能力篩選、失敗分組已有列在其他來源後續分頁中保留；既有過期查詢／底層取消與其他用例回歸不變。工程引用及 production factory／renderer 提交／詳情路由已追蹤，無需改工程、renderer 或詳情的既有 action。

**限制**：eacg／forest／kanba／youknow 仍回 HTTP 403，fengche／hanime1 仍格式不符；本次修復路由及呈現，不冒充全站可用。Bilibili 訪客搜尋對未知字串可能給模糊匹配，空結果驗收改用真實 girigiri 空回應，不過濾遠端合法命中。內建 JSPlayer 對 Bilibili 保留既有能力拒絕，實播改用已支援 mpv；已觀察不同畫面，但不能由送出 seek 鍵推斷 seek 成功。App 正式退出 exit 0，owned mpv 另以 SIGTERM 清除，listener 消失；原 IINA 保留。一次性 AX／smoke／雜湊工具移除，profile 與去敏證據保留。未驗證真實彈幕、播放器多視窗／重連、有效帳號、最低系統／Intel 或 R7 全矩陣；R2–R7、M2／M3／MT3／M4 與 W8.3 門檻不變。

<a id="r2-navigation"></a>
#### 5.5.0.2 R2 導航空白與重開狀態（2026-10-11 已完成）

- **根因／修復**：原 renderer 對每次導航重建 shell／wrapper，scroll 未限制填滿剩餘寬度，外層 stack 的 gravity sizing 可把搜尋維持在請求的 760×640，留下右側／底部空白。現以 renderedPageID＋activePages 拒絕同頁無變更重建；換頁先卸載舊 shell，再重掛既有 instance owner。主內容寬度明確等於 shell 扣除側欄，host 底邊固定，工具列使用 stack 垂直 hugging，避免把空白搬到工具列。Layout／預覽及 capability 變更仍使畫面失效並重繪。
- **生命週期**：關窗 detach 取消查詢／訂閱，但保留已完成的搜尋快照、控制項、詳情與設定 owner；重開 attach 冪等恢復觀察。載入中的搜尋走既有 cancelSearch／generation 隔離。移除 Layout instance 仍 detach 並移除 owner。Torrent 關窗仍釋放未提交匯入與儲存權限，重開建立新匯入畫面；不恢復已撤銷的 native grant，不停止已提交下載。App controller／session state／工程及資料模型無需變更。
- **建置／入口**：Debug BUILD SUCCEEDED；正式 AppDelegate／Workspace，Bundle ID org.iina-ani.r2-navigation，產物 .build/xcode/Build/Products/Debug/IINA+.app，實作 dylib SHA-256 `61909bccdcc071e25cbb6634a493254da6c8c01ec37a16dda3571fd08090c1c2`。最終單實例驗收使用 .build/r2/acceptance-home；啟動前關閉所有本輪迭代 App，原 IINA 保留；lsof 確認最終 App 自身綁定 127.0.0.1:19080。未複製／清除私人帳號或原收藏。

| 正式操作／結果 | 證據（.build/r2/evidence/） |
| --- | --- |
| 1280×800／960×640 內容尺寸搜尋同頁各 20 次，搜尋↔收藏交替 20 輪；寬視窗外 scroll 1096×759，窄視窗 776×599，無新增空白區；其他四個可見頁各連點 20 次 | single-wide20／single-narrow20 的 AX／PNG／actions、single-alternate20.actions.txt、single-other-pages20.actions.txt |
| 分頁搜尋 → 收藏 → 返回 → 原生關窗 → 固定「開啟工作區」選單：結果、query／來源影片分類／全部來源、六站錯誤與 scrollbar 0.4 全部保留；最終一次重開為 47 筆 | single-bili-before／single-bili-closed／single-bili-reopened 的 AX、single-bili-reopened.png；檔名 bili 為工具命名，實際來源篩選以 AX／PNG 的全部來源為準 |
| 補充來源篩選：bilibili 20→40 筆，返回／真正關窗／固定選單重開維持 bilibili／分類與 scrollbar 0.4→0.3999692 | proven-state-before／proven-state-closed／proven-state-reopened 的 AX／PNG |
| 設定及普通 BV 網址詳情真正關窗／固定選單重開，保留目前頁面及影片標題／網址；關窗 AX 沒有 AXWindow | single-settings-reopened.ax.txt、single-media-closed.ax.txt、single-media-reopened.ax.txt／.png |
| 載入中真正關窗 → 重開 → 等待 6 秒，顯示「搜尋已取消」／0 筆，沒有晚到結果 | single-cancel-closed.ax.txt、single-cancel-reopened.ax.txt／.png |

**內部定位**：最終來源的一次 debugger 觀察，在 20 輪交替與同頁連點後，host 下 1 個 shell、service owners 5、favorite owners 2、search owner 1、history 41；同頁沒有追加 history，跨頁才追加。此觀察不是長時間 heap 洩漏證明。

**回歸／限制**：Tests/run-workspace-layout.sh、Tests/run-w7-usecases.sh 全部通過；本輪以正式 UI smoke 驗證 renderer，不新增只檢查 wiring／原始碼的永久測試。早期按鍵派送／來源 popup／截圖定位工具曾未完成操作，未把派送成功當作關窗或選擇成功；最终以原生 AXCloseButton、無視窗 AX 及實際重開結果為準。最終 App 由正式結束選單退出 exit 0，所有本輪 App 清除。未實播、彈幕、有效帳號、P2P、最低系統／Intel或完整重啟持久化驗收；R2 的重開指同一 App 行程關窗再開，R3–R7／M2／M3／MT3／M4／W8.3 門檻不變。

<a id="r3-classification"></a>
#### 5.5.0.3 R3 類型隔離（2026-10-11 已完成）

- **分類與身份（2026-10-11 域名規則更新）**：SourceSelection、搜尋結果與 Work 保存種類及出處，不改 SourceItemRef、Work／Episode UUID。Jibi／Dilidili 加入純番劇來源；Fqdm 明確宣告番劇，未宣告配置未知；Forest 內建配置移除，持久收藏保留。Bilibili `/video/` 統一一般影片，不細分搬運動畫；直播保持原路由。Bilibili `/bangumi/play/` 與 Didahd／Kanba／YouKnow／Rebo 以來源作品名進行匿名 Bangumi type=2 二級查詢：原名／中文名／別名標準化精確匹配、遍歷全部分頁、唯一作品為番劇、成功無匹配為一般影片（影視劇）、歧義／缺標題／失敗待確認，取消向外傳遞。替換舊 PGC result.type 分類，不自動關聯 subject ID；手動分類優先。
- **搜尋與路由**：BrowseContentFilter 六個分区屬同一查詢快照，來源游標與分類保留於分頁；過濾後空頁仍保留可用遠端游標，替換分類取消舊查詢並拒絕晚到回應。直播關鍵詞不請求 Bangumi。搜尋傳遞完整 selection；發現頁傳遞 subject 元資料，分類在目錄／解析／準備鏈保持。收藏與精確 source/page 連結採持久 Work 分類，手動修正優先於刷新。
- **命令與持久化**：非番劇不提供 Bangumi 關聯／番劇集數映射；BangumiWorkSync 在修改前取得動畫元資料，拒絕真人或未知，保留舊關聯並防止刷新覆寫手動分類。一般內容仍可保存 generic 來源連結。直播在 UI 及 DownloadService／DownloadSourceResolver 拒絕下載，即使 ref 形狀為 video 也不可錄影。分類修正只修改原 Work，保留收藏／來源／集數／下載。AppDelegate 先做 WorkClassificationMigration 一致 SQLite 副本，再遷移既有 JSON payload，metadata 版本為 IINA.WorkClassificationMigration.version=1；副本位於 <store>.r3-backup/backup.sqlite，保留未知 payload 欄位、可 rollback／離線還原，重跑不重建身份。
- **建置／正式入口**：README Debug xcodebuild 命令加 PRODUCT_BUNDLE_IDENTIFIER=org.iina-ani.r3-types，BUILD SUCCEEDED；產物 .build/xcode/Build/Products/Debug/IINA+.app。最終實作 dylib SHA-256 bafe9c8119e8d4c75eb90e74027801e307f90e9fba6d0107f262240e19cc34e5。HOME／CFFIXED_USER_HOME 均為 .build/r3/acceptance-home，走正式 AppDelegate，不以 host 代替；Core Data 為該 home 的 Library/Application Support/IINA+/DataModel.sqlite，服務資料在獨立 bundle 目錄。最終 PID 30337 正常退出後重啟為 30547，loopback 127.0.0.1:19080；最終正常退出且 listener 消失。未複製或清除私人帳號／收藏，原 profile 本輪未做前後雜湊，不沿用舊輪「未變」宣稱。

**本輪二級分類驗證**：Debug 建置及 run-w3-sources、run-w4-bangumi、run-w7-usecases、run-workspace-layout 通過；真實 Bangumi「葬送のフリーレン」唯一匹配為番劇、無匹配標題為一般影片，正式 App 網址搜尋 ss46089 顯示番劇及 unique 出處。證據 `.build/r3-domain/evidence/`；使用隔離 HOME，未實播或逐站驗證混合來源。下列原 R3 驗收表為先前一輪歷史證據。

| 正式操作／結果 | 證據（.build/r3/evidence/） |
| --- | --- |
| 葬送的芙莉莲：同名動畫 type=2、真人節目 type=6、書籍 type=1 分別為番劇／一般影片／待確認；番劇分區不收普通 BV，即使標題含動畫名 | keyword-all／keyword-anime 的 AX／PNG |
| 一般影片分區 21→41 筆（Bangumi 真人 1＋Bilibili 20→40）；More Results 保留關鍵詞／分類／來源；未知分區明示待確認，直播分區不混入動畫 | keyword-video.ax.txt、keyword-video-page2 的 AX／PNG、keyword-unknown 的 AX／PNG、keyword-live.ax.txt |
| 普通 BV1xx411c7mD URL 可獨立解析至 480P，無番劇關聯／映射；Forest URL 明示未知，不自動判作動畫 | video-detail-final 的 AX／PNG、final-unknown-detail 的 AX／PNG |
| Bangumi 390200 動畫詳情 → 嘗試關聯真人 73955（type=6）被拒絕，提示只接受已確認動畫；原 UUID／390200 保留 | final-anime-detail.ax.txt、final-rejected-drama 的 AX／PNG、rejected-drama-store.txt |
| Bilibili live/1010 未開播：仍為直播與原房間，無番劇命令，下載停用，明示未開播；App 不再崩潰 | final-native-live 的 AX／PNG、live-room.json |
| 未知 Forest 來源保存為原 Work；390200 手動修正為一般影片 → 正式結束 → 完整重啟 → 收藏／URL 重開仍為 video/manual，原兩個 UUID、收藏及 Forest 連結保留，非番劇命令不出現 | correction-store.txt、restart-store.txt、restart-favorites 的 AX／PNG、restart-corrected-detail 的 AX／PNG |
| 發現頁實際推薦卡 FX戰士久留美 → 番劇詳情，保留動畫元資料及番劇命令 | recommendation-detail-final 的 AX／PNG |

**回歸與限制**：Tests/run-work-library.sh、run-w5-favorites.sh、run-w4-bangumi.sh、run-w3-sources.sh、run-w7-usecases.sh、run-workspace-layout.sh 通過；來源／用例以最後建置再跑，日誌保存在 evidence。永久回歸覆蓋混合站分類、未知解碼、六類過濾／跨空頁游標／替換取消、真人關聯拒絕、手動刷新優先、直播下載拒絕、SQLite 副本／rollback／重跑與 Work／Episode／收藏身份保留。正式 live/1010 先觸發既有無串流 debug assertion；修正 decodeUrl 在解析前檢查 info.isLiving，後驗證為正常未開播錯誤，沒有抑制線上解析失敗 assertion。部分站仍返回 HTTP 403／格式錯誤，Forest 詳情遠端失敗不當作可播放；PGC 類型分支以回歸資料驗證，不冒充全站實播。沒有新增站點、直播錄影、P2P、有效帳號驗收、mpv／彈幕實播或最低系統／Intel 證據。臨時 AX 操作工具已清除，去敏證據及隔離 profile 保留。R4 固定詳情、R6 自動尋源、R7 全矩陣與 M2／M3／MT3／M4／W8.3 關卡不因 R3 通過。

<a id="r4-detail"></a>
#### 5.5.0.4 R4 固定詳情格式（2026-10-11 已完成）

**交付**：WorkspaceDetailController 是各詳情入口的既有單一呈現 owner；內部固定為「海報／縮圖與標題、原名、類型、年份、來源 → 簡介與資訊 → 作品集數／來源集數或分 P → 播放、來源、品質、收藏與下載」。一般影片顯示作者及原始連結，直播顯示主播／在線狀態，不呈現季集表、番劇關聯／映射、作品收藏或錄影下載。未知內容明示待確認，不代猜作品身份。

**版面與維護**：標題預設 24 pt 並按可用寬度換行；動畫海報框 2:3、影片／直播縮圖框 16:9，保留原圖比例。集數／分 P 列為單行摘要，完整文字可由提示／無障礙取得；表高隨內容縮短並有上限，無資料時改為區域空狀態，不留空表。空標題／時長顯示未知。分類修正、Bangumi／來源關聯及映射收於預設收合的「更多」，保留原命令與 R3 分類守門。原 Registry／Layout／Skin 槽不變；Skin 字體／顏色仍可覆蓋，不能重排內部語義區塊。

**正式產物與隔離**：README 的 Debug arm64 無簽署建置通過；正式驗收另以 PRODUCT_BUNDLE_IDENTIFIER=org.iina-ani.r4-detail 建置同一份來源，啟動 .build/xcode/Build/Products/Debug/IINA+.app/Contents/MacOS/IINA+，走正式 AppDelegate。HOME／CFFIXED_USER_HOME 指向 .build/r4/home，沒有複製／清除私人帳號或收藏。最終建置為 build-final3.log；SHA-256、正式入口／資料路徑、情境清單及正常退出結果見 .build/r4/evidence/runtime.json、final-build-sha256.txt。原 profile 本輪未做前後雜湊，不沿用前輪未變宣稱。

| 正式操作／結果 | 證據（.build/r4/evidence/） |
| --- | --- |
| Bangumi subject 390200 的搜尋结果 → 詳情 → 收藏 → 完整退出重啟 → 收藏重開；同一作品資料及固定模板，維護表單預設收合 | anime-detail／anime-favorite-final 的 AX；anime-favorite-1280.png、anime-960-top／actions／more 的 PNG、anime-960-more.ax.txt |
| 一般 BV1xx411c7mD：作者／站點／原始連結、單一影片空狀態與 480P；播放可用、既有下載能力拒絕保留，無番劇控制項 | video-960.ax.txt、video-960／actions.png、video-1280.png |
| BV1wD4y1o7AS 長標題與多分 P：窄視窗換行；實際選第二分 P，原始連結為 ?p=2，480P 與播放按鈕可用，未自動播放 | multipart-light／multipart-selected-light 的 AX／PNG |
| 實際推薦 subject 545008：中文／日文原名、長雙語簡介及集數；960×640／1280×800 的資訊與操作均可捲動到達 | recommendation-light-960.ax.txt、recommendation-light-960-top-final／actions-final.png、recommendation-top-retry.png |
| Forest 未知來源解析失敗：缺圖／簡介未知／區域錯誤，不留空表；透過更多明確改為本機番劇後，缺集數呈現文字空狀態 | unknown-960 的 AX／PNG、unknown-more.ax.txt；local-anime-menu.ax.txt、local-anime-empty 的 AX／PNG |
| live.bilibili.com/1010 未開播：主播／房間／在線狀態保留，沒有集數或下載控制項；最終來源顯示直播專用失敗原因 | live-1280.ax.txt、live-1280／live-960 的 PNG；final-live-dark 的 AX／PNG |
| 匯入並套用 Contour Minimal 1.0.0，未勾選作者 Layout；淺／深色真實主視窗保持固定區塊和主要操作。內建外觀亦操作兩種尺寸與明暗模式 | skin-preview-ready.ax.txt、skin-local-anime／skin-local-anime-dark 的 AX／PNG |
| 最終來源 subject 636512：正篇／OP／ED 穩定列保留，缺標題／時長明示未知，元資料載入完成不殘留載入中狀態 | final-episode-placeholders 的 AX／PNG |

**回歸與限制**：Tests/run-workspace-layout.sh、run-skin-appearance.sh、run-w7-usecases.sh 通過；最後一項包含既有搜尋／精確分 P／收藏／離線下載等回歸。原生版面以正式 App 操作與截圖證明，沒有加入原碼字串／wiring 測試。未新增網站、資料模型、P2P 或播放器；本輪沒有按播放啟動實播／彈幕，也沒有驗證有效帳號、macOS 13.5／Intel。直播未開播與 Forest 遠端錯誤不是播放通過。R5–R7、M2／M3／MT3／M4／W8.3 保留；R6 自動尋源／播放選單尚未實作。臨時 AX 工具及含私人檔名的選檔樹已清除，去敏證據與隔離 profile 保留。

<a id="r5-settings"></a>
#### 5.5.0.5 R5 設定層級（2026-10-11 已完成）

**實作**：WorkspaceSettingsController 將分類下拉選單改為五個常駐原生 radio，選中狀態與可及性 ID 對應同一分類；左側分類、右側搜尋／設定項維持兩層。設定項用 flipped document stack 從頂端開始，僅項目內部捲動；分類及搜尋不隨長表單捲走。分類欄正常字級優先 148 pt，但不壓縮放大字級標題；分類／搜尋高度依字型計算。沿用既有同義詞／分類搜尋，選結果切分類、捲至實際項目並聚焦，狀態列明示目的地；關於只保留版本／歸屬。

**Owner／安全**：WorkspaceRenderer 獨立持有全域 settingsController，不再跟 Layout 組件 instance ID 一同移除。側欄、⌘,、原生設定選單及折疊／移除設定組件後的固定入口重用同一 owner。完整設定頁限制外層文件高度，保留項目內部捲動。WorkspaceApplicationController／WorkspaceSettingsSearch、Preferences／帳號／下載 owners 及 Skin／Layout 隔離預覽、套用／取消、破壞性確認契約均沿用，沒有第二套服務或相容 shim。

**正式產物**：本份來源 Debug arm64 build-final8.log 為 BUILD SUCCEEDED；`.build/xcode/Build/Products/Debug/IINA+.app`，Bundle ID `org.iina-ani.r5-settings`，HOME／CFFIXED_USER_HOME 指向 `.build/r5/home`，實際 AppDelegate／主視窗，非隔離 UI host。Contour Minimal 1.0.0 取自 R4 隔離公開 fixture，未複製真實帳號／收藏，未套用作者 Layout。最終 PID 37701 正常退出，19080 listener 消失；產物雜湊與執行紀錄見 `.build/r5/evidence/final-binary-sha256.txt`／runtime.json。中間驗收曾有較早隔離 App 持有 listener，已正常退出後才啟動最終產物；不將中間埠衝突當作服務驗收。

| 正式操作／結果 | 證據（.build/r5/evidence/） |
| --- | --- |
| 五分類切換、兩層表單及關於的版本／歸屬；960×640 內容 pt，內建淺深色及自訂深色；1280×800 內容 pt 仍填滿 | final8-category-0…4 的 AX／PNG、final8-wide.png／final8-wide-geometry.txt；內建淺色 light-wide-category-0…4 與 light-narrow-sources-final.png |
| mpv 查詢選第二個結果，直接聚焦實際 mpv 路徑；分類名稱搜尋亦定位到該組設定 | final8-click-focus.ax.txt、category-search-focus-final.ax.txt／PNG |
| 放大 31 pt 分類／搜尋仍完整可達；「缓存 清除」Enter 直接聚焦清理快取按鈕，長表單自動捲至項目，沒有執行清理 | final-font31-narrow.png、final8-cache-focus.ax.txt／PNG |
| 側欄／原生設定選單／⌘, 重用選中分類；⌘W 關窗、固定選單重開保留焦點目的地；全域彈幕開關退出重啟仍保留 | menu-owner-final.ax.txt、final8-shortcut-owner／final8-closed／final8-reopened 的 AX；persisted-preference-final5.ax.txt |
| 原生 Layout 編輯選取設定組件、折疊並保存後，固定設定入口保留先前分類，搜尋仍直達 | editor-collapsed.ax.txt、collapsed-recovery-final／recovery-search-final 的 AX／PNG；最終產物 final8-category-* 仍走此固定入口 |

**回歸與限制**：Tests/run-workspace-layout.sh、run-skin-appearance.sh、run-w7-usecases.sh，以及既有 WorkspaceSettingsSearchRegression 均通過。沒有新增原碼字串／wiring 永久測試；暫時 AX／搜尋執行檔及含私人 Recent Items 的樹已清除。未驗有效帳號登入、真實播放／彈幕／下載、首次 P2P、macOS 13.5／Intel 或完整 VoiceOver 朗讀；AX 名稱／焦點不等於 VoiceOver 驗收。31 pt 下既有工作區工具列及部分原生按鈕仍有字形裁切，不宣稱全 App 放大字級矩陣通過，保留 R7 視覺關卡。R6／R7、M2／M3／MT3／M4／W8.3 不代簽；原 profile 未做前後雜湊。

<a id="r6-anime"></a>
#### 5.5.1 R6 番劇尋源與帳號契約（2026-10-11 已完成）

**2026-10-12 入口與排版切換**：以下尋源／帳號契約沿用；詳情改為作品摘要、選集主區及簡介／人物／關聯／評論分頁，播放只由應用內來源窗口提交。此輪僅 Debug 建置與離線回歸，未啟動 App；本節 2026-10-11 正式 App 證據保留為歷史，不當作新版介面驗收。

- 「番劇」在本輪指動畫作品流程，涵蓋 TV／WEB／OVA／劇場版；保留具體子類型，不把劇場版硬塞成電視季集。一般影片／分 P／直播不因標題含動畫名就進入此流程。
- 使用者在一級詳情選集、開啟來源二級窗口即確認本次播放意圖，不再按尋源鈕開始。自動有界尋源，已有對應該集的保存映射優先；否則沿用啟用來源與作品原名／中文名／別名。有唯一可信候選即解析並播放；多候選或作品證據不足時核對候選名稱並選來源即解析播放，沒有額外來源確認或播放確認按鈕。只進作品詳情、換皮或 resize 不自動尋源。
- 分清「搜尋命中」「作品匹配」「集數映射」「本次解析成功」；標題相同不足以自動綁定。季別／年份／作品型態衝突排除，正篇／SP／OVA 沿用穩定集數身份。前台只列具有所選精確集數、且無拒絕／失敗原因的候選；其餘保留於預設折疊的來源診斷，不造成選項干擾。同名證據不足的候選不自動播放；解析成功後才保存精確關聯。
- 詳情旧「播放 ▾」與 App 固定播放選單仍已移除；播放意圖只從一級選集及二級匹配來源流程進入，不另建播放器。二級不顯示來源集數／分 P 網格，不能重選或改播另一集；品質／線路／播放器保留。普通影片／尚無作品集數的直接來源流程仍保留原精確分 P／來源選集，不將番劇鎖集規則套用至無一級選集的影片。
- 沒有匹配或解析失敗時不猜第一集、不暗換站；故障來源移出前台選項，詳細原因保留於診斷。重新尋源不自行重播，仍可選來源直接播放。连按開窗僅尋源／提交一次，換集／取消／關窗／離頁後晚回應不得啟播或覆寫新頁；關窗不撤回已提交播放。一般影片既有自動開啟偏好不因番劇入口切換而刪除。
- **2026-10-13 BT 播放整合**：二級來源窗口提供「線上來源／BT 搜尋與播放」切換；切入 BT 取消未完成線上自動播放。BT 以作品名預填可編輯查詢，按 `https://sub.creamycake.org/v1/bt1.json` 的 RSS `searchConfig.searchUrl` 搜尋；搜尋結果不等同所選集數映射，須明選結果、同意 P2P、讀 metadata、明選精確影片後邊下邊播。全域 magnet／Torrent 檔案選單改走同一窗口，舊 torrent.import 組件供自訂編排保留。關窗／換集取消未提交 BT 工作，已提交播放／下載仍由原 owner 管理；不新增 BT JSPlayer 或自動集數綁定。
- **2026-10-14 快速下載**：詳情提供獨立下載窗口及在線／BT 分頁。在線先明選作品來源，再從該來源精確目錄以核取方塊選多集，驗證品質、線路與既有下載能力後批次提交；換來源清除未提交勾選與解析。BT 以 metadata 的影片檔案核取方塊批次提交，單列播放選擇與下載勾選分離，快速下載頁不顯示播放控制。無預選、無未匹配集數猜測；番劇 guest 與來源授權政策維持。成功提交項目在本次窗口內排除重試，失敗／未就緒保留；關窗與取消只停止未提交工作，已提交傳輸留在共用下載頁。
- 「不顯式使用帳號」採保守決策：番劇尋源／播放介面不出現帳號選單、不要求選號或登入，公開來源預設 guest；不為了成功而暗取全域預設帳號、Cookie 或 Bangumi OAuth。需要登入／付費權限的候選標示不可用，提供其他公開來源／開啟原站，不繞過授權。既有來源帳號管理及非番劇顯式授權流程不刪除；若未來需要背景使用已授權帳號，須另定政策，不在本輪偷偷加入。
- 尋源與解析沿用 SourceRegistry／VideoDecoder 及既有播放命令；不複製帳號池、HTTP client 或傳輸引擎。新行為不得將 Bangumi subject URL 交給影片解析器，也不將搜尋成功當成可播放。

**2026-10-11 實作記錄（選單及自動模式已由上述 2026-10-12 入口替代）**：`AnimeSourceService` 沿用 registry／decoder 的搜尋、目錄、解析與 prepare 邊界；最多 3 站／目錄同時執行、4 個去重名稱、每站首頁 8 個去重作品。先檢查保存的同作品／同集映射；新命中須有作品及明確集號證據，僅同名維持手動確認。解析得到所選品質／線路的非空媒體後才保存 WorkSourceLink／EpisodeSourceMapping，媒體 URL 不持久化。重搜按作品與集數身份去重，不以品質／線路區分同集。

`VideoDecoder.guestSelection` 清除繼承 HTTP context 並禁止預設帳號；番劇 UI 不列帳號，既有原生動畫解析的 30 個 HTTP 請求改沿用 AccountHTTP，避免讀全域 Cookie jar。JSPlayer 保留原能力，使用非持久 WebKit store／不共享 Cookie 的 URLSession，憑證仍由 pinned decoder scope 負責。詳情與 App 固定選單共用屏幕 owner；取消／離頁改 generation，單次提交後不暗換站。同集重載通知不再撤銷已提交狀態；候選選單直接加入 NSMenuItem，避免同名標題移除引起索引錯位。

**正式 App 證據**：Debug arm64、`org.iina-ani.r6-sources`、隔離 HOME／CFFIXED_USER_HOME；未使用真实播放帳號。最終產物 `build-final2.log`／`final-binary-sha256.txt`，`final2-app`／`final3-app` 為同一產物。證據位於 `.build/r6/evidence/`，AX 已移除私人選單。

| 正式操作／結果 | 證據 |
| --- | --- |
| 第 2 集多站候選；Jibi／XiFan 的第二季拒選，保存映射與搜尋同集不重複；明確選 Jibi 沒有選到錯季 | final-candidates.ax.txt／PNG、final-jibi-choice.ax.txt／PNG |
| 明確選 XiFan，第 2 集 guest 已提交；mpv 解碼 1920×1080，280.363417 → 283.366417 秒，duration 1560.976083 秒 | final2-xifan.ax.txt、final2-playback.json；較早同集實播畫面 mpv-episode2.png |
| 保存來源退出重開，第 2 集精確映射直接自動播放；重載後再次連按自動播放不增加提交（啟動計數維持 6） | restored-detail.ax.txt、automatic-restored.ax.txt、final2-submitted-menu.ax.txt、mpv-launches.txt |
| 正在尋源時按取消，離頁後晚回應沒有候選 sheet／新啟播；取消候選 sheet 亦未啟播 | final3-loading.ax.txt、final3-cancel-button.ax.txt、final3-cancel-late.ax.txt、cancelled.ax.txt |
| SP1 缺少來源精確集數，錯季與缺集原因可見；沒有可選播放候選，確認播放停用，不回退正篇 1 | final3-missing-sp.ax.txt／PNG |
| 無番劇詳情上下文／直播時固定番劇命令停用；既有 B 站直播 room 6 透過 JSPlayer guest 實播 | final-no-context.ax.txt、final3-live-detail.ax.txt、final3-jsplayer.ax.txt／PNG、final3-app.log |
| Jibi 第 2 集頁面可解析／保存；提交後媒體 TLS EOF，沒有暗換到 XiFan | final-jibi-result.ax.txt、jibi-media-failure.json |

**回歸與限制**：`run-w7-usecases.sh`（含 AnimeSourceRegression）、`run-w2-services.sh`、`run-w3-sources.sh`、`run-workspace-layout.sh`、`run-skin-appearance.sh` 通過。永久行為回歸涵蓋季／年／型態／SP／劇場版、同線重複集號、保存／重搜去重與品質保留、guest、解析失敗、部分站失敗及取消晚回應；重搜去重有 failing-before／passing-after。未以 fixture 簽收真實付費／需登入來源、全站、IINA 外掛／彈幕、下載、macOS 13.5／Intel 或完整 VoiceOver。XiFan 未宣告 JSPlayer 能力，仍明示不可用；沒有新增其 Web 播放支援。中途 debugger attach 受簽署限制使較早隔離程序 SIGKILL，已重開驗證；最終 PID 39704 正常退出、19080 listener 消失。原 profile 未做前後雜湊；R7、M2／M3／MT3／M4／W8.3 保留。臨時工具、含 signed media 的診斷及私人 AX 樹清除。

#### 5.5.2 正式 App 驗收矩陣

| 範圍 | 必須操作的情境 | 判定與證據 |
| --- | --- | --- |
| 搜尋 | 中文／原名關鍵詞、一般影片 URL／番劇 URL、支援的短網址、空白輸入、無結果、來源部分失敗、快速改查詢、取消、翻頁後返回 | 每個分區有結果或明確狀態；舊查詢不覆寫新查詢；URL 不依賴 Bangumi 可用；實際點擊可進正確詳情 |
| 空白佔位 | 同側欄項連按 20 次、交替切頁 20 輪、同結果重複開啟、詳情返回、載入中離頁、關窗重開；兩種視窗寬度 | 視覺無累積空白；僅預期容器／controller 存活、約束不累積；查詢與滾動正確恢復，已提交下載不受影響 |
| 類型 | 同名動畫／一般影片、不同季、SP、劇場版、分 P、直播及未知；搜尋／收藏／URL／推薦各入口 | 不混排成同類、不錯路由；非番劇無自動番劇映射；未知明示；既有資料身份不變，重啟不重複 |
| 詳情 | 番劇、一般影片、直播；長標題／簡介、缺圖、缺集數、失敗；1280×800／960×640、深淺色 | 固定區塊次序、文字可讀、主要操作可達；無空表佔位、無分類不適用控制項；Skin 不改变模板語義 |
| 設定 | 由側欄與 ⌘, 進入，逐類修改並重啟；搜尋同義詞後直達；帳號刷新與返回 | 分類 → 設定項最多兩層；鍵盤與 VoiceOver 可辨識；值／焦點不丟失，作用範圍清楚 |
| 尋源／播放 | 無帳號 profile；唯一匹配、多候選、零候選、錯季、缺集、部分站失敗／需登入、取消後切作品、手動換源、連按播放 | 無帳號選擇／隱式憑證；唯一可信映射自動播放，其餘明示選擇／失敗；IINA／mpv 實際載入正確集數，JSPlayer 按原能力另驗 |
| 持久化／回歸 | 保存來源映射、重開、舊資料副本遷移、既有收藏／下載／彈幕操作 | 不錯綁、不丟資料、不停止獨立任務；不以新 guest 流程代替既有 W2／M2 帳號驗收 |

每包保存建置命令／產物、操作步驟、樣本與時間、截圖、觀察到的實際结果及未通過項。網路／授權／外部播放器或設備不可用時明列受阻，不以 fixture 結果補簽。永久回歸只保留錯查詢覆寫、路由重複、類型／集數誤配、取消晚回應啟播等具體行為風險；原生版面以實際視窗驗證，不寫原碼字串斷言。

<a id="r7-acceptance"></a>
#### 5.5.3 R7 集中結果與受阻報告（2026-10-11–12）

**R7 集中結果／報告已交付，不是全旅程或 M2／M3／MT3／M4／W8.3 簽收。** 依 §8.3 僅使用未開始、進行中、受阻、已驗收四狀態；必要子項失敗／缺環境即整列受阻。§5.5.2 七列及 §8.1 十四項原目標、§8 品質門檻與歷史 R0–R6 全部保留。

**環境／證據**：macOS 27.0.1（26A434）、Apple M4 Pro、24 GiB、12 CPU、arm64，未簽署 Debug；本機歷史記錄 `.build/r7/evidence/build-final7.log` 成功，最終產物身份見 final-binary-sha256.txt。正式 AppDelegate／真實原生視窗，驗收配置使用隔離 HOME／CFFIXED_USER_HOME 與 Bundle ID `org.iina-ani.r7-acceptance`；證據根 `.build/r7/evidence`（本機產物，不隨 Git 發佈；此處保留歷史位置，不保證仍存在）。1280×800／960×640 為內容 pt。鎖屏、menu-bar／黑圖或擷取失敗不作產品通過證據；native AX 与已檢視的有效 PNG 分開記錄。無真實憑證／公網 P2P 同意，未做原 profile 前後雜湊。午夜崩潰後一次 open -a 意外重啟 PID46648，沒有 HOME 隔離；此輪排除，後續改用指定 PID 的檔案 AppleEvent，最終已終止該 owned PID，不能宣稱原資料完全未變。Huya／Archive 外部 IINA 喚起既有 PID76128 的新 receiver；僅關閉確認為本輪公開媒體的 receiver 視窗，原 IINA 行程保留。

##### §5.5.2 七列结果

| 範圍 | 狀態 | 正式觀察／未簽收項 |
| --- | --- | --- |
| 搜尋 | 已驗收 | 中文／原名 47 筆，分頁 87；普通 BV1xx411c7mD、Bangumi URL、b23、空白、girigiri 真空結果、部分來源 403／格式錯誤、快速替換／取消晚回應及返回。390200 為列女戰紀，芙莉蓮為 400602，不以錯標樣本簽收；真 Bangumi 斷網另見旅程 2。 |
| 空白佔位 | 受阻 | 兩寬度同頁 20 次／交替 20 輪、詳情返回 5 次、載入離頁、關窗無 AXWindow／固定入口重開，視覺無累積空白；R7 controller／constraint heap 存活未量測，R2 歷史數量不代簽。 |
| 類型 | 已驗收 | 動畫／影片／直播／未知隔離，錯季／SP 拒絕、劇場版 Your Name（160209）正式 final3-movie-detail、普通影片分 P；七項遷移身份重開不重複。 |
| 詳情 | 已驗收 | 固定模板、長／缺失狀態、正常字級明暗及寬窄正式 AX／PNG；不代表 31 pt 全 App 通過。 |
| 設定 | 受阻 | 側欄／⌘,、五分類、缓存／快取 Enter 聚焦 storage.download.directory；EACG 停用、guest 刷新、mpv 路徑、併發 3、推薦關閉及重啟值。final6 才實際選 mpv，final7-mpv-preference-cold-reopened AX 確認 enum=mpv／正確路徑；final7-owned-command-comma 以 owned PID 聚焦后原生 ⌘, 開設定。完整 VoiceOver 未完成。 |
| 尋源／播放 | 受阻 | guest 芙莉蓮 XiFan 第 2 集 mpv 1920×1080、duration 1560.976083、time 17.26725→20.27025、seek 實到 600.85025；五按僅一次 launch、保存映射冷啟動自動播放。取消離頁／錯季／SP1 不回退；Jibi 第二線第 2 集提交後新 mpv 退出／IPC 拒絕，不用 R6 TLS 推定本次原因。XiFan JSPlayer 能力拒絕；Bili live 6 JSPlayer 兩幀時鐘 13:25→13:29，彈幕／重連／釋放未全證明。 |
| 持久化／回歸 | 受阻 | 作品／連結收藏、映射重開、v0.3 格式七項遷移及三真下載／暫停重啟／恢復／取消隔離有證據；彈幕全鏈與兩真帳號／M2 未由 guest 替代。 |

##### 缺陷、永久修復與有效回歸

- WorkspaceModel 對 Set／dictionary 作 canonical Layout digest；SkinPackageStore 真確認交易修前 invalidConfirmation／layoutIdentity 失敗，修後通過，不是文字／接線測試。
- WorkspaceSkinPresentation 保護原生 switch／radio image／imagePosition，設定分類繼承 themed button；Full Skin 正式分類 AXCheckBox 修為 AXRadioButton，原生語義保留。
- DownloadModels.fractionCompleted 保留已知暫停 bytes、completed=1，ServicePanel 刪過時 fallback；regression-download-progress-before／after 暫停 65% 修前失敗／修後通過，正式 native indicator 65%／完成 1。
- WorkspaceSessionState 顯式 throwing init(storeURL:)，schema 1 私有 instance-state-v1.json 原子保存／錯誤回報／移除 pruning；App／Renderer／Favorites／Services 全呼叫端切換。查詢／來源篩選／選中／捲動不混入 Layout／Skin。非同步 sourceIDs 前先恢復 bootstrap；兩搜尋實例 girigiri／bilibili 修前冷啟動 All／All，final4-first／second-filter-reopened 修後各自正確。regression-layout-durable-state-final 涵蓋欄位／刪除／corrupt／future schema／磁碟錯誤，選中／捲動冷啟動目前只有回歸，不冒充正式表面。
- 壞私有檔啟動明示錯誤；workspace nil 時固定恢復入口仍可達，NSAlert 明確取消／備份後重設。取消保留 33 bytes cmp 0、同意後備份 cmp 0、defaultLayout 恢復及 ⌘, 可用；見 recovery-cancel-preserves-bytes.log、recovery-backup-preserves-bytes.log、private-state-*，不靜默丟棄。
- Internet Archive fixture jsonEpisodeTitlePath title→name 符合真 metadata，隔離配置同步；SourceEngine 未改、無新網站／能力。regression-w3-live-config-field-final 六項通過，正式配置能力見旅程 7。
- 真實 2026-10-12 00:00:06 午夜通知在 background queue 進入 MainActor selector，SIGTRAP／_dispatch_assert_queue_fail（midnight-crash-before.json）。WorkspaceServicePanelController.refreshForDayChange 改為 nonisolated 接收；主線直接處理，背景轉主 queue，weak self／attached 防止離頁後重刷。final7 正式 App 臨時 DYLD 探針從背景送 NSCalendarDayChanged，觀察 POST_RETURNED／MAIN_QUEUE_AFTER_DAY 及正式原生導覽回應（app-final7-background-day.log、day-change-background-*.ax.txt）；另以無注入冷啟動確認 19080 為 owned PID，無永久測試 hook。這不代簽真遠端新增集／重排。

##### §8.1 十四項逐項結果

| 旅程 | 狀態 | 正式證據／缺口 |
| --- | --- | --- |
| 1 作品／關聯／非首集線路／播放／收藏重啟 | 受阻 | 芙莉蓮第 2 集 XiFan 真 mpv、收藏映射重開通過；明選 Jibi 第二線提交但退出，非首線實播未通過。 |
| 2 普通 URL／連結收藏／再播／Bangumi 斷網 | 受阻 | Bili 真 mpv 512×384、duration 2055.599、time 48.266→49.0，連結收藏重開通過；正式 Bangumi 真斷網未做。 |
| 3 跨日排期／新增集／重排 | 受阻 | 實際午夜崩潰已修，final7 正式 App 背景跨日通知／主線回應通過；W7 日期／新增集／重排回歸通過。沒有跨日新增集真遠端樣本，不代簽。 |
| 4 HTTP／HLS 下載恢复尾段取消 | 受阻 | Archive 非首 ed_1024_512kb 47,065,346 bytes、首 ed_1024 67,835,590、Sintel 282,690,045 完成，completed-download-probes.log 有 ffprobe／hash。Sintel 184,156,016 bytes（65.144%）暫停真退出重啟恢复完成；非首完成檔 mpv 426×240、duration 653.791667、尾 seek 647.583333、eof=false。新 promo 取消保留三完成鄰居。W6 真 loopback HLS 通過，正式遠端 HLS 完成未做。 |
| 5 內建／自訂外觀全頁重啟 | 受阻 | Minimal／Full 原生取消／套用、正常字級明暗及乾淨 profile 重匯入；31 pt 工具列／按鈕已知裁切未修，完整焦點／錯誤／對比未量化。 |
| 6 兩帳號／失效登入／快取隔離 | 受阻 | 無兩真有效帳號／重新授權；不以合成憑證代簽，歷史使用者登入確認保留。 |
| 7 純配置重載搜尋選集真播 | 已驗收 | SourceEngine 未改；Archive 宣告 keyword 搜尋 settled 27（7 Bangumi＋20 Archive）、URL／非首 ed_1024_512kb／詳情／下載；正式 direct remote mpv 426×240、duration 653.791667、time 116.791667→119.791667，非僅本機完成檔。archive-configured-search-settled／archive-keyboard-exact-nonfirst／archive-configured-real-play-submitted 留證。 |
| 8 舊庫遷移／逐能力回歸 | 受阻 | authentic v0.3 格式合成七項含 fractional order／duplicates／p2／live／unknown／broken；migration-first／reopened 七 distinct ID，favoriteTitle／remark／URL／order／UUID／created／source／canonical 穩定，liveTitle 更新非丟資料。Bili 點播／JSPlayer 已播；Huya 660000 既有 IINA 新 receiver，/huya/UUID.flv GET、guest WS heartbeat／停止／重新連線見 huya-proxy-and-plugin.log 及 app-final6-main.log；Huya 畫面／rendered 彈幕／完整釋放未齊。Bili loadDM 曾 Key not found:data.data，不簽彈幕。 |
| 9 Torrent 正式產品全鏈 | 受阻 | W11 loopback／HTTP Range 回歸通過，正式 metadata／非首檔／缺塊 seek／reader 隔離全旅程未做；PUBLICNETWORK:true 未執行，無公網 P2P 同意，MT3 保留。 |
| 10 編排跨欄私有狀態恢復 | 受阻 | duplicate 搜尋、640×320、移到 Discovery、undo／redo／保存、兩來源篩選冷重啟；Favorites split 以「上移」鍵盤等價控制跨欄，AX 樹先 links→works、撤銷／重做，保存冷重啟後還原 works→links（layout-cross-column-*.ax.txt、已檢視 layout-cross-column-return-cold.png）。final7-first／second-filter-confirmed-before／after AX 各自 girigiri／internet-archive；先前 final4 為 girigiri／bilibili。隱藏下載不中斷、停用 ACTIVE 明示 activeID 拒絕、固定任務入口可達；新隔離 profile 預設 Favorites 960 雙欄／Search 可操作，final7-default-favorites-double-column-960.png 已檢視。實際滑鼠拖曳、選中／捲動冷重啟正式證明未齊。 |
| 11 Skin 分享／Layout 分離 | 受阻 | 原／衍生匯出乾淨 profile 重匯入，26 assets 一致、export-package-audit.json 無私有欄位／archive 絕對路徑；純 Skin 保留 Layout，作者 Layout 明選替換，移除留 tasks。完整焦點／停用／錯誤可達性未完成。 |
| 12 外部 JS helper 正式旅程 | 受阻 | layout-script-formal-policy-refusal 正式「佈局腳本尚未開放／外部腳本匯入仍受安全關卡保護」；W8.3=false，缺最低系統／正式 Sandbox，不用 helper 回歸代簽。 |
| 13 壞包／合法最大／替換／恢復 | 受阻 | bad-zip-modal-layer-final 原生拒絕；合法 expanded 64 MiB／256 entries 正式 preview／apply，使用已檢視 skin-maximum-preview-exact.png，不以只拍主頁的舊圖代簽。同 ID v1→v2 確認／取消重開／繼續預覽套用 skin-replacement-*。native-rejection-observations.json 記路徑／case collision／連結／CRC／加密／巢狀包／壓縮及量限制、缺引用／未知格式／版本、重複 ID／深度／非法尺寸的原生拒絕 AX；typed 非法尺寸與真正有效 8192×8192 PNG（67,108,864>64,000,000 pixels）拒絕另留證，後者已檢視 reject-excessive-pixels-valid.png，早期損壞 PNG 不算像素界線。catalog／Layout／下載 before/after SHA256 cmp0。替換素材快取不殘留的正式表面尚未量證，保留受阻。 |
| 14 操作數鍵盤 VoiceOver 兩尺寸 | 受阻 | Enter 搜尋、設定直達、選集、Skin／恢復及兩尺寸有 AX／focus；全流程操作數未全記。VoiceOver 真啟動，但 lastphrase -1728／cursor timeout，AX 不等於語音通過；完整 VO／對比／放大字級未簽。 |

##### 容量與品質門檻

1000 合成本機收藏走 production favorites，寬窄及 0999／0001 可操作。capacity-latency.jsonl 是單次 AX command＋Enter＋poll 端到端觀測；observer/setup 排除，command／poll overhead 包含，不是純渲染耗時／分位數／200 ms 保證，網路延遲另記。數值僅於下表比較一次：

| 操作 | 觀測 ms | §8.2 的 200 ms 目標 |
| --- | ---: | --- |
| AX 本機切頁 | 108.7125 | 此樣本低於，非普遍簽收 |
| 提交篩選 | 223.8100 | 高於，受阻 |
| 清空篩選 | 244.6908 | 高於，受阻 |
| 窄窗操作 | 223.4282 | 高於，受阻 |

- 功能／穩定性受阻：各旅程缺項、R7 heap／constraint、全彈幕 release 未證明，歷史 R2 不代簽。
- UI／可達性受阻：正常字級明暗／兩尺寸／容量有正式證據，R5 已知 31 pt glyph clipping 未修；完整 VoiceOver、對比／放大字級未通過。
- 資料安全受阻：遷移、原子私有狀態／壞檔備份、Skin 隱私及下載隔離有局部證據；午夜崩潰後一次未隔離 owned 重啟已排除／終止，但沒有原 profile 前後雜湊，不作完全隔離聲明。真帳號／全快取隔離及所有歷史 evidence 去敏不由局部結果推定。privacy-and-integrity-audit.json 是有限範圍審核，最終新增文字另作 delta 審核；未檢視的 PNG 不稱已視覺验收。
- 相容性／發佈受阻：缺 Intel、macOS 13.5、正式簽署 Sandbox／Developer ID／公證。M2／M3／MT3／M4／W8.3 保持未簽收，外部腳本 false；unsigned Debug 不代表可發佈。
- W1 library／W2／W3／W4／W5／W6／W7、Layout、Skin appearance／package、layout script、dependency --unit、W11 loopback／HTTP Range 已有通過日誌；最終 binary 的 Tests/run-w7-usecases.sh 亦通過（regression-w7-final7.log）。永久 fail-before/pass-after、正式表面及背景日界 runtime smoke 分開，不以測試數量代替旅程。一次性 AX／DYLD／生成工具驗證後移除，保留 evidence／隔離 profile／包樣本。

<a id="plan-ui"></a>
## 6. UI、組件與自訂體驗

本節是 W8／W9 的完整交付規格，不是現有能力清單。原 M2 前置及目前驗證限制見 §0／§5；新頁面消費既有真實服務，不讓視覺方案改變作品身份、帳號或下載狀態機。

### 6.1 視覺語言

以「安靜的影音收藏室＋每日放送手帳」為方向，而不是網站首頁移植。

- 預設深色：墨藍底 `#151922`、分層面板 `#202735`、暖白正文 `#EEF1F5`、琥珀主操作 `#E8B86D`、青綠更新提示 `#78C9BE`。這些是設計起點，交付前按實際文字／背景組合測量對比。
- 同一套語義提供淺色版本，支持跟隨系統；不只把深色值反轉。
- 特色來自日期排版、細線分區、海報比例及更新標記；不靠全屏漸層、過量毛玻璃或自動輪播。
- 使用系統字體；標題 22–28 pt、正文 13–15 pt、輔助文字至少 11 pt。間距以 4／8 pt 為單位；預設卡片圓角 10 pt。
- 作品卡以 2:3 海報呈現；普通影片以 16:9 縮圖呈現。Discovery 卡片的番名改於固定深色毛玻璃浮層懸浮／鍵盤導覽選中時顯示，短淡入淡出遵守降低動態效果；新集數摘要維持可見。搜尋及收藏列表保留常駐名稱，操作於聚焦或選中時清楚可達。
- 顏色不單獨表達狀態；更新、失效、下載中皆有文字或圖示。動畫短且可停用，尊重系統降低動態效果。

### 6.2 資訊架構與版面

內建預設主側欄為**發現、搜尋、收藏、下載**，設置位於底部；此為初始工作區而非禁止自訂。使用者可依 §6.3 排列／隱藏可選導覽及新增頁。作品詳情與影片詳情仍是內容路由；預設全域搜尋／貼網址保持可見，自訂後亦須由固定選單／快捷入口可達。

```text
┌──────────┬──────────────────────────────────────────┐
│ IINA-ANI │ 返回   搜尋作品、影片或貼上網址      任務狀態 │
│          ├──────────────────────────────────────────┤
│ 發現     │ Trends 頂置／下滑推薦；右上角日曆按鈕      │
│ 搜尋     │                                          │
│ 收藏     │ 收藏更新；作品與原始連結雙欄                │
│ 下載     │                                          │
│          │ 詳情內：作品資訊 → 集數 → 來源與品質 → 播放 │
│ 設置     │                                          │
└──────────┴──────────────────────────────────────────┘
```

- 初始設計畫布 1280×800 pt，最低驗收視窗 960×640 pt；側欄約 176–208 pt，內容按可用寬度增減卡片列數。
- 內建收藏預設為真正雙欄：**劇集／作品｜影片／連結**，有獨立標題、數量、排序與空狀態，分隔線可拖曳。最低視窗的內建版面仍保留兩欄，不以 Tab 假裝交付雙欄；使用者可另存自訂排列，恢復預設必須回到雙欄。長標題截斷並可查看全文。
- 詳情頁主區顯示海報、中文／原名、年份、簡介、資訊來源及更新時間；操作區集中收藏、播放、下載。切線路與品質不另跳多個彈窗。
- 普通影片詳情保留原始連結、站點與分 P；沒有 Bangumi 關聯也必須可播放、收藏及下載。
- 空、載入、成功、局部失敗是各內容區狀態，不用全屏遮罩阻塞其他區域。網路錯誤不得顯示成「沒有作品」。
- 鍵盤：搜尋 `⌘F`、設置 `⌘,`、Tab 焦點順序、Return 開啟選中項；Escape 只退出當前浮層／操作，不取消背景下載。返回保留查詢、篩選與滾動位置。
- 詳情採固定語義模板（[R4 已完成](#r4-detail)）：頂部海報／縮圖＋標題／原名／類型／年份／來源，接簡介與資訊，再選集／分 P，最後集中播放／來源／品質／收藏／下載。番劇使用作品與集數；一般影片使用作者／站點／分 P；直播使用主播／在線狀態／品質，不顯示虛構季集。缺資料顯示未知或區域空狀態，不留大塊空表。關聯／映射等維護命令收於「更多」，日常不呈現技術表單。Skin 可改外觀，Layout 可放置詳情組件，但詳情內部的語義次序與主要操作不能被任意打散。

### 6.3 組件化工作區、可分享 Skin 與受限佈局腳本

本階段必交組件自由編排、可選非基礎功能、可分享 Skin 及受限佈局腳本；外觀、排列與業務功能各自持有狀態，不是另一套播放器或插件平台。

#### 6.3.1 設計結論與研究入口

osu 的素材覆蓋、集中換皮、版本化佈局與可分享包用作設計借鑑；不引入遊戲框架、不相容 .osk、不序列化程式類名。受限 JS 佈局生成是本專案設計，不是已由 osu 證明的沙箱能力。17 個固定版本原碼／授權引用及採用／不採用理由集中於 [附錄 B.1](#research-osu)。

#### 6.3.2 架構與組件契約

採「固定恢復外殼＋可編排工作區＋資料式 Skin」；沿用 AppKit 視窗生命週期與現有 SwiftUI 整合，不全面重造文字輸入、選單、捲動或無障礙系統。新頁面從一開始消費可替換樣式與素材，不先硬編碼再補 Skin。

- 業務服務仍由既有 AppServices／各服務持有；組件只讀狀態、發型別化命令。Skin、腳本、佈局都不能直接持有 Cookie、資料庫或播放器 handle。
- Skin（外觀）、Layout（排列）、Preferences（功能偏好）分開保存。換 Skin 預設不換 Layout，不改功能開關；可選套用作者佈局，先預覽差異再確認。
- 組件目錄只登記 App 內已實作且接上真實服務的組件，非動態原生插件註冊平台。粒度為全週放送、收藏更新、推薦、作品清單、連結清單、搜尋結果、作品資訊、集數選擇及下載任務等完整任務面板。
- 每類組件公開穩定 typeID、契約版本、參數 schema、預設／最小尺寸、允許容器、是否可重複、依賴能力、可用樣式槽與可設定項。每個實例有穩定 instanceID；不以陣列下標、顯示名稱或程式類名辨識。
- 組件實例持有自己的篩選、分頁、選中與滾動狀態；同類清單可有多實例，業務資料仍只有一份。拖曳、換皮、撤銷不重發播放／下載命令；移除面板只取消其專屬查詢／訂閱，不取消獨立任务。
- 共用素材解析結果由外觀 owner 管理，組件不各自合併樣式或重新解碼。快取 key 包含 Skin 安裝修訂、素材 ID、顯示縮放及必要呈現參數；替換同名素材不能讀到前版。背景大圖按展示尺寸處理、按需載入，釋放無人使用的舊修訂；不每幀讀檔或執行腳本。

#### 6.3.3 自由編排與可選功能

- 預設版面遵循 §6.2；工作區可新增頁、選首頁、排序導覽、跨欄移動、調尺寸、增刪／折疊組件。內建收藏雙欄始終是可恢復的預設，不以自訂能力削減原定交付。
- 一般編輯器支援吸附網格、水平／垂直 stack、split、group、tabs；提供尺寸限制及視窗寬度斷點。腳本可生成更深的巢狀容器、不同斷點排列與批量參數化實例，比單純拖曳更自由。不將任意旋轉／重疊像素畫布作為閱讀型 UI 的必要前提。
- 明確區分日常模式和編輯模式；只有編輯模式顯示拖曳把手、容器邊界及新增組件。提供鍵盤移動／調整的等價入口，不能只靠拖曳。
- 拖曳以一次完成的手勢為一筆撤銷；新增、刪除、跨頁移動及整份佈局套用各是一筆工作區交易。取消預覽不動已保存版本，確認後原子保存；重啟保留最後有效文件，不需重跑作者腳本。啟動讀到损壞文件時明示原因並用內建工作區恢復可操作性，保留原文件供修復，不覆寫使用者業務資料。
- 「隱藏組件」僅變更呈現；「停用非基礎功能」阻止新操作／其可選背景刷新；「刪除資料」是獨立命令。活動下載、播放或被其他能力使用的服務不能隨面板卸載；停用遇活動任務時列出影響並拒絕，讓使用者另行停止或取消停用，不暗停／暗刪。
- W8.1 固定能力清單及依賴：推薦、排期／更新刷新等可選；下載與彈幕按既有服務可用性提供停用。停用一個呈現組件不等於停用底層能力。被停用功能的資料保留，重新啟用可再見；元資料、收藏保存與必要任務管理不跟著可選推薦一起關閉。
- 設置、恢復內建外觀／佈局、活動任務管理與全域搜尋／開啟入口始終從 App 固定選單／快捷入口可達，不能被作者 Skin 或自訂工作區移除。隱藏導覽項不刪功能或資料。

#### 6.3.4 Skin 能力、覆蓋與包格式

Skin 不只是 token 配色：必交全域色彩／字級／間距／圓角／邊框／密度，背景／圖示／占位／裝飾素材，以及作品卡、列表、搜尋框、導覽、主要操作、分頁、進度條的公開样式槽。元件狀態涵蓋 normal、hover、pressed、selected、focus、disabled、loading、error；業務規則、狀態文案、可存取名稱及點擊範圍由 App 控制，裝飾不能覆蓋安全操作。

- 內建深／淺色及跟隨系統持續必交；第三方包宣告支持的明暗變體，切至缺少的變體前明示，不自動反色冒充作者版本。包可攜帶有授權的字體；字體不足的字形由系統字體補足，不將正文烘焙成圖片。
- 樣式合併由低到高為「內建基底 → Skin 定義 → 該 Skin 的個人覆寫」。使用者覆寫按 Skin ID 保存，換另一包不帶入前包的私人修改。作者可只定義部分槽，不必複製全部基底。
- 同一按鈕等相關素材採成組解析；自訂組至少有 normal，缺其他狀態使用契約定義的原生焦點／停用等效果，不各自撿入另一 Skin 的不相容圖像。引用了不存在／损壞的檔案屬錯誤，與省略可選槽不同。
- 內建主題正文對比 4.5:1、大字與關鍵非文字控件 3:1；第三方低對比警示但不強行改色。恢復、安全提示與權限確認使用可信原生呈現，保持可達。尊重降低動態效果；此範圍不含音效、影片背景、任意 shader 或原生控件程式替換。
- 圖片採 PNG／JPEG，保留透明及高解析度縮放資訊；字體採受支持的 TTF／OTF。初期不載入可執行 SVG／HTML／遠端素材。新增格式須經解碼安全及相容驗證，不以「圖片副檔名」代替內容驗證。

現行 v1 使用 ZIP 容器與 `.iinaskin` 副檔名，UTF-8 JSON／素材可直接編輯，不需專用編譯器。W8.4 已加入 App 檔案關聯；獨立發佈身分仍未配置，不據此承諾跨未來格式版本相容。實際格式與可匯入範例見 [作者文件](../../Examples/Skins/README.md)。

| 路徑 | 契約 |
| --- | --- |
| manifest.json（必要） | schemaVersion、穩定 id、name、author、version、revision、最低 App／組件契約版本、明暗變體、入口路徑、授權及素材歸屬；作者 metadata 不是驗證簽章 |
| theme.json（必要） | 語義 token、內建基底與變體；不含帳號、功能開關或本機路徑 |
| components.json（可選） | 已公開組件／狀態槽的樣式與素材 ID，不含程式類名 |
| assets/、fonts/（可選） | 隨包素材、字體與授權聲明；只允許相對包根的引用 |
| manifest.layout（可選） | 內嵌版本化 Layout JSON；現行 ZIP 拒絕 `.js` 及 layouts/ 入口，不因安裝或重載授予腳本執行權 |
| preview.png（可選） | 作者展示圖；不作實際呈現正確性或安全性證據 |

Layout 文件與 Skin 文件各有 schemaVersion；Layout 保存 pageID、節點 kind、typeID／組件版本、instanceID、尺寸／容器／斷點及允許的展示參數。未知必要節點／版本、重複身份、非法尺寸、超深樹或循環引用必須拒絕。使用 typeID 映射已知原生組件，不反射／動態載入作者程式。格式升版先遷移副本再驗證，保留原檔；新版本不支援時不靜默丟字段後保存。

#### 6.3.5 匯入、分享、作者工具與安全

使用者流程：拖入／開啟包 → 驗證與 App 實際預覽 → 套用；預設「只套外觀」，「外觀＋作者佈局」需明確選擇。Skin 管理頁提供已安裝清單、版本／作者／授權、移除、匯出與恢復。第三方作者圖只作列表展示；預覽使用本 App 原生組件，操作命令隔離，不啟動播放／下載或提交偏好。

- 安裝到自有 Skin 目錄，以 staging 驗證後原子提交；不修改原包、不直接將 ZIP 展開到任意使用者目錄。相同 ID／相同內容重匯入去重；同 ID 不同內容或版本列出差異，明確確認替換，不視為作者已驗證的自動更新，失敗保持舊安裝與目前選擇。
- 拒絕絕對／越界路徑、符號／硬連結、正規化後重名（含大小寫／Unicode 碰撞）、加密／多層壓縮包及非允許類型。以實際串流解壓 bytes 限制檔案数、單檔／總量；解碼前限制像素與字體大小，不能只信 ZIP header。W8.2 須把具體上限記入格式契約並用合法最大包與越界包驗證，未定上限不得開放外部包。
- 素材引用不得存取包根之外或遠端 URL；不載入 dylib、命令、HTML bridge。安裝 Skin 不授予腳本執行權。帳號憑證、收藏／歷史內容、下載檔案、完整簽名 URL、本機絕對路徑不進分享包。
- 匯出採允許清單，由有效模型與其素材生成，不遞迴打包整個使用者目錄；必需素材缺失則中止並報錯。提供「作者原包」與「含個人外觀微調／選定佈局的衍生包」，衍生包生成新 ID 並保留來源 ID、作者與授權，不偽裝成原作者更新。分享佈局只帶展示結構與非敏感參數，不帶私人搜尋文字、帳號／作品資料或任務快照。
- Skin 移除不刪 Layout、收藏或 Preferences；移除目前包前先切到內建基底。包提供的佈局套用後成為獨立工作區副本，不能因刪 Skin 失去導覽。
- 作者支援載入本機目錄、明確「重新載入並預覽」、檔案／欄位錯誤定位；同樣經過包驗證與路徑限制，不以開發模式繞過腳本隔離。交付最小覆蓋與完整素材兩個可匯入範例、格式與組件槽文件。此為作者編輯文字／素材的流程，不另造圖片／字體繪製軟體。
- 分享走檔案即可，不做線上市場、評分、雲端同步或自動下載更新。匯出保留授權，不將工具可打包等同於有權再散布；未聲明／不允許再散布的素材須提示，使用者承擔取得授權責任。

#### 6.3.6 真正的受限佈局腳本

支援 JavaScript `buildLayout(context)` 產生同一 Layout 文件，而不是將 JSON 匯入冒稱為腳本。輸入只含格式／組件能力版本、可用組件清單及使用者明確給定的非敏感配置；輸出是 JSON 可序列化的頁面／組件樹。腳本可使用函式、迴圈、條件批量生成佈局及宣告寬度斷點，不新增原生組件、不更改業務規則。

- 腳本執行於可終止的獨立受限 helper，不在主執行緒、View body 或播放器 WebKit bridge 執行；不提供檔案、網路、程序、Keychain、App 物件或動態模組載入接口。僅沒有暴露 bridge 不是安全沙箱證據，須一併證明 helper 的作業系統權限限制。
- 父程序限制牆鐘時間、輸入／輸出大小；引擎／程序限制記憶體，佈局驗證器限制深度、節點數與參數大小。單純背景 Task、逾時後忽略結果或抓 exception 不能停止無限迴圈。W8.3 在 macOS 13.5 與發佈 sandbox／簽署條件下選定並驗證引擎及限制機制，再提供匯入入口；不得以未證明可終止的執行器交付。
- 第一次執行及腳本內容變更後須由使用者明確觸發；純外觀安裝／啟動 App／視窗縮放不得執行作者碼。斷點由原生渲染器解讀已保存的 Layout。輸出驗證、實際預覽通過後才套用，超限、錯誤或不相容保留原工作區，提供腳本位置／欄位錯誤。
- 同一份 Layout 供腳本、拖曳、預覽、儲存與匯出使用。腳本產物可繼續手動編排，不做從 Layout 反向生成 JS；重跑腳本先預覽替換差異，確認才覆蓋手動版本，整筆可撤銷。分享成品可只帶 JSON，使接收方不必執行腳本。
- 脚本自由度來自巢狀容器、斷點及参数化，而不是任意 UI 程式執行。作者可重排設定頁的白名單設定項 ID，不能自行生成登入表單、覆寫安全文案、移除恢復入口或更改設定驗證。

#### 6.3.7 驗收責任

W8 必須交付實際可用的編排、Skin 包及受限腳本，不只格式／空註冊表。W9 接上全部產品頁與真實資料，W10 簽收跨頁、鍵盤、最小系統與既有能力回歸。§8.1 新旅程涵蓋重排／重啟、純換皮不換佈局、分享去敏、脚本失败隔離與設定步數；只通過解析／單元不能宣稱完整 UI 驗收。当前仍遵守頁首暫停整體驗收政策，待 UI 完成後集中執行。

原生選單、系統授權窗及外部 IINA／mpv 不承諾由 Skin 控制；內建播放器既有彈幕外觀設定維持獨立，不讓自訂 UI 改變外掛協議。

### 6.4 將已完成模塊接入具體頁面

| 頁面 | 使用的既有功能 | UI 整合工作與驗收 |
| --- | --- | --- |
| 發現 | W4 排期、W5 收藏、W7 更新／推薦 | 全週放送以日曆彈窗呈現、收藏更新在收藏頁、Trends 與推薦流在發現頁；呈現資料出處與推薦理由；點擊進正確作品／集數；局部錯誤不遮住其他區 |
| 搜尋 | W7 搜尋用例、W3 URL 解析 | 共用關鍵詞／URL 框、分類、來源篩選、分頁；快速輸入不顯示過期結果；返回保留查詢、篩選及滾動位置 |
| 作品／影片詳情 | W3 解析、W4 資訊／關聯、W5 收藏、W6 下載 | 資訊、來源、集數／分 P、線路、品質及只讀登入狀態，無帳號切換；手動關聯／解除；播放與下載用相同選擇；根據能力呈現操作及不可用原因 |
| 收藏 | W5 兩類收藏查詢與命令 | 真正「作品｜連結」雙欄，各自搜尋、排序、刪除；欄寬可拖動且重啟保存；失效連結仍可查看／修改；刪收藏不刪下載 |
| 下載 | W6 任務命令、進度事件及完成檔 | 清單、速度、可得的剩餘時間、未知總量及封裝狀態；暫停／恢復／取消按鈕只在可用狀態提供；完成可顯示於 Finder 及用播放器打開 |
| 設置 | W2 偏好／號池／快取、W6 任務約束、W8 Skin／Layout | 外觀與佈局、來源與帳號、播放與彈幕、下載與儲存、關於五組；§6.5 搜尋直達／就地修改，作用範圍明確且有真實效果 |

Torrent UI 與 W11.4 共用本表頁面：搜尋／開啟入口接受 magnet 與本機 .torrent，詳情顯示 metadata／精確檔案選擇，下載頁沿用同一任務 owner，設置接入實際上傳限速／停止及快取保護；不另造 BT 控制台。須原 M2 與 MT2 通過才整合；W9 結案包含這些新增項目。

設置頁具體驗收：

- 外觀與佈局：§6.3 全部能力及 §6.5 流程可用，預覽與套用分開；取消還原、重設可達；Skin／Layout 匯出不含私人資料與憑證，分享包再匯入後能實際呈現。
- 來源與帳號：主頁僅三站狀態與登入／登出、來源訂閱入口，不展開來源能力、配置重載或號池管理。三站登入／授權前後能由固定按鈕與 Esc 退出；取消／重開不累積身份。登入失效可重新授權，使用中登出由服務拒絕且提示。來源訂閱子窗口可檢查、預覽、明確套用與捨棄，關閉取消未提交工作；舊雙帳號安全驗收留在服務層，不要求恢復切換 UI。
- 播放：既有 IINA／mpv、JSPlayer、品質及彈幕設定都有新落點且行為不變，不冒稱未接入能力。
- 下載與快取：顯示目錄、併發數、用量與清理範圍；改目錄只影響新任務。實際下載中清快取不刪活動暫存、收藏、帳號或完成檔。
- 錯誤、未知值、空結果及登入失效依服務狀態呈現，不在 View 自動補假資料或重試；重啟後偏好仍在。

### 6.5 設定層級與操作成本

預設不用自訂就可完整使用；日常動作留在內容旁，編排動作只在編輯模式，全域偏好才進設定。只替換外觀與恢復佈局不動收藏、帳號或下載策略。

- 五組設定固定按目的分為「外觀與佈局」「來源與帳號」「播放與彈幕」「下載與儲存」「關於」。分類導覽常駐、目前分類清楚標示，側欄／⌘,／選單指向同一設定 owner；不堆在單頁要求逐段尋找。「關於」不收納無關進階功能；進階項在所属分類就地展開。實例設定明示「只影響此組件」，避免與全域偏好混淆。
- 一般設定維持「分類 → 設定項」兩層；帳號授權使用可取消 sheet，來源訂閱的長差異預覽使用獨立子窗口；不能讓播放器／品質切換連續跳多個對話框。搜尋支援同義詞／分類名稱，直接定位並聚焦設定項；在自訂佈局中被隱藏的項目仍可從可信設定入口打開。
- 組件選單直接修改該實例的資料範圍、排序與密度；全域設定與單實例覆寫明示作用範圍，不同入口讀寫同一狀態。Skin 個人覆寫與功能偏好分開，不隨外觀包分享。
- 一般可逆偏好即改即生效；Skin／Layout 用隔離预覽＋明確套用，不每個顏色都加確認。删除資料、使用中帳號、首次 P2P 上傳等保留必要說明／確認；減少步驟不省略安全邊界。
- 功能停用項直接顯示依賴、活動任務阻擋及重新啟用入口。缺能力顯示原因，不用無作用按鈕或悄悄改用其他帳號掩蓋。

| 情境／起點 | 目標流程與步數計法 |
| --- | --- |
| 已在詳情且有有效播放選擇 | 一次啟動操作播放；無有效選擇／登入失效時不強行滿足一步而猜測來源 |
| 調整單個組件 | 組件選單 → 本地設定，共兩次開啟操作；修改值另計，不跳全域設定 |
| 改工作區排列 | 進入編輯 → 拖曳；一次手勢是一筆撤銷，結束編輯保存；不需逐組件確認 |
| 找到設定 | 從設定搜尋輸入關鍵字 → 選結果直接聚焦；不再進子分類逐層尋找 |
| 匯入 Skin | 選檔／拖入 → 預覽 → 套用；純外觀不額外要求腳本授權 |
| 恢復可用介面 | 固定選單 → 恢復內建外觀／佈局；各自可恢復，不重設業務資料 |

以上為完整旅程的驗收目標；R5 的分類／兩層設定／搜尋／owner 與正式視窗證據見 [R5](#r5-settings)，不代表其他旅程或完整可及性矩陣通過。W9／R7 記錄每條旅程的起點、點擊／鍵盤操作、錯誤與必要例外；輸入字數、拖曳距離及網路等待不混算為設定層級。鍵盤、VoiceOver、1280×800／960×640 pt、長文字與放大字級都須可達。

<a id="plan-engineering"></a>
## 7. 工程原則與複雜度控制

保留必要安全邊界，刪除沒有具體失敗場景支持的機制。

| 要做 | 不做 |
| --- | --- |
| 外部回應、配置文件、使用者輸入及持久化遷移在邊界驗證 | 每個內部方法重複檢查相同 invariant |
| 缺封面用明確占位；缺作品關聯顯示未關聯 | 用假標題、假集數、空 URL 或空集合掩蓋解析失敗 |
| 來源適配器處理本站必要差異 | 在 UI 堆 host 判斷、特殊 ID、隨機 header 或未證實的備援路徑 |
| 可取消請求、明確超時、必要的有界操作 | 所有層各加重試、無限退避、失敗後自動換帳號／來源 |
| 只在資料、下載檔與憑證等真實不可逆操作前確認 | 每次跳頁、播放、搜尋都加確認彈窗 |
| 一個來源接口及必要能力，沿用實際資料存取 | 通用 repository 工廠、全域 service locator、插件總線、多層同形 DTO |
| 一次性 schema 遷移及可還原資料副本 | 為未知舊版永久維持雙寫、別名及舊 UI 相容層 |
| 以觀察到的問題決定日誌與測試 | 遙測平台、所有方法包 catch、只測轉發／字串／預設值 |

評審新抽象前回答：有哪兩個現存使用方？共用的是行為還是只有名稱？拿掉此層會造成什麼可證明的重複或錯誤？答不出就留在當前模塊。外部錯誤可恢復，內部不可能狀態應在開發中暴露，不吞掉後繼續運作。

<a id="plan-acceptance"></a>
## 8. 總驗收標準與證據

本節為最終 UI／產品驗收規格；2026-10-11 已恢復正式旅程，按 §5.5 修復後逐項執行。基礎行為依 §4，功能閉環依 §5.2；不得以單元／編譯或歷史局部證據替代完整驗收。

### 8.1 必跑的 UI 整合旅程

1. 搜尋作品 → 取得 Bangumi 資料 → 人工確認來源關聯 → 選非第一集／非第一線路 → IINA 或 mpv 實際載入 → 加入作品欄 → 重啟後資料一致。
2. 貼普通影片 URL → 查看資訊 → 加入連結欄 → 再開啟播放；Bangumi 斷網時仍成立。
3. 跨日開發現頁 → 排期可見 → 已收藏作品新增集數顯示来源更新 → 點擊進正確集數；舊目錄重排不報新。
4. 詳情下載直連檔／HLS → 暫停或中斷重啟 → 恢復 → 完成檔播放及定位尾段；取消只清理本任務。
5. 切內建深／淺色與系統模式 → 自訂 token／素材樣式 → 取消／套用 → 匯出再匯入 → 重啟；四主頁、兩種詳情及設置外觀一致；Skin 包與腳本另依旅程 11／12 驗收。
6. 三站登入／取消／重開 → 登入失效重新授權／登出 → 清快取；身份、收藏與下載不受誤改。直播／影片只有登入狀態，沒有切換帳號。既有同站兩帳號的憑證／任務隔離仍在服務層驗證，不恢復多帳號 UI。
7. 只新增符合既定規則的 source 配置 → 重載 → 搜尋（若宣告支持）／貼 URL → 詳情選集 → 真實播放；程式無改動。
8. 舊資料副本遷移 → 比對項目及排序 → 再啟動無重複；既有直播、點播、JSPlayer、彈幕、虎牙代理按能力矩陣逐項回歸。
9. 匯入 magnet／本機 .torrent → metadata → 選多檔 torrent 的非首個影片 → 未完成時由外部 IINA／mpv 載入並 seek 尚未下載區域 → 建立／保留獨立下載 → 關播放器不誤停下載 → 收藏／重開維持同一檔案 → 完成檔播放；分別驗證取消 reader、停止上傳、清快取及刪記錄／刪檔隔離。
10. 進編輯模式 → 新增同類清單的不同篩選實例 → 跨頁／跨欄移動及調尺寸 → 撤銷／重做 → 重啟；實例身份、各自篩選與選中不互換。隱藏下載面板不終止活動任務；停用有活動任務的功能明示拒絕；最小視窗仍能操作並恢復預設雙欄。
11. 匯入僅部分覆蓋及完整素材的兩份 .iinaskin → 實際預覽／取消／套用 → 匯出到乾淨隔離 profile 再匯入；樣式與素材一致，缺省槽正確繼承、焦點／停用／錯誤可辨識，包內無私人資料。純換皮不改 Layout，另選作者佈局才替換，移除 Skin 仍保留工作區及任務。
12. 匯入 JS → 生成多層／多斷點 Layout → 預覽／套用 → 手動拖曳 → 重跑預覽／取消或確認 → 撤銷 → 重啟；重啟不自動執行、不在 resize 執行，無私密輸入。無限迴圈、超量記憶體／輸出、讀檔／網路企圖均不能突破 helper 邊界或卡住 App，原 Layout 保留。
13. 壞 ZIP、越界／重名／連結素材、缺失引用、超量解壓／像素、未知格式／組件版本、重複 instanceID、非法尺寸及過深佈局各在相應邊界明確失敗；不部分安裝、不損壞目前 Skin／Layout。合法最大包可用，替換同 ID 舊包需確認且素材快取不殘留，恢復入口始終可達。
14. 依 §6.5 完成播放、組件設定、全域設定搜尋、Skin 匯入及恢復，記錄實際操作數；鍵盤等價流程、VoiceOver 與兩種視窗尺寸通過。設定項的自訂位置不改其語義、安全確認或作用範圍。

### 8.2 品質門檻

- 功能：第 4 節功能、第 5 節關卡與第 6 節 UI 驗收全部完成；來源缺能力明示，而非回傳假成功。外站故障需記錄樣本、時間與原因，標為未通過／受阻，不算完成或偷偷縮小驗收。
- UI：1280×800 與 960×640 pt、深／淺色、長標題、空資料、1000 筆本機收藏場景可操作；列表使用按需渲染，不在頁面載入時解析所有串流。1000 筆是容量場景，不是網路抓取要求。
- 響應：本機資料的切頁／篩選以可交互 200 ms 為目標；下載進度不引發全列表高頻重建。記錄測量機器、樣本與結果；網路延遲單獨記錄，不用假延時或空白遮罩美化數據。
- 可達性：鍵盤完成搜尋、收藏、選集、下載與設置；VoiceOver 可辨識名稱及狀態；焦點可见，狀態不僅靠顏色，內建主題符合第 6 節對比目標。
- 穩定性：快速搜尋、切頁、關窗、取消、多播放視窗與下载並存時無跨任務污染；關閉播放視窗釋放其任務與彈幕訂閱，不終止獨立下載。
- 資料安全：無書籤丟失、無錯集／錯帳號、無下載覆盖；快取清理不碰持久資料；日誌與匯出不包含 Cookie、token 或完整簽名串流 URL。
- 相容性：在宣告最低系統及當前開發系統驗證。沒有相應環境時標為未驗證，不能稱全面完成；不得為了使用新 UI API 悄悄提高部署目標。
- 發佈：工程仍沿用 IINA+ 身分的風險依 [PROJECT.md](../architecture/PROJECT.md) 處理；UI 完成不等於可獨立發佈，不觸發上游更新、不混用真實資料目錄。

### 8.3 驗證方法與結案格式

- 現行政策：已恢復正式 App 端到端驗收；日常執行受影響回歸／編譯及真實操作，集中驗收按 §5.5／§8.1。
- UI 使用本份來源產出的 App，從正式 AppDelegate 冷啟動，保存去敏結果、持久化／恢復及實際視窗證據。隔離 host／單元不替代正式登入、播放、下載或 UI 驗收。
- 測試以最小有效集合為原則：只保留能捕捉具體使用者可見錯誤、重要邊界或狀態轉移的回歸；新增永久測試須對應已觀察缺陷、尚不確定的風險邊界或使用者明確要求，不以測試數量／覆蓋率作為工作量或完成度。身份、帳號隔離、遷移、取消及檔案保護等必要驗收不能因提速省略。
- 減少非必要測試項：不測單純接線／轉發／mock 回聲、原始碼文字、文案、偶然預設值、僅不拋錯／非空或同一路徑的重複斷言；同一 invariant 在能可靠捕捉錯誤的最小層驗證，不在每層再複製一套。既有此類測試應刪除或合併，不隨實作改寫後重新固定；一次性觀察以臨時煙霧程式完成，驗證後移除。
- 日常採增量構建：只建置受影響 target，執行受影響契約及直接依賴的必要測試／煙霧；相關修改批次完成後驗證，不在每個小改動後重跑整個 App 或全量回歸，也不重複編譯相同生產模組。純文檔改動只檢查文檔，不觸發 App 構建或測試。
- 完整回歸留在跨模塊整合、W7／W10 關卡及發佈前；只有共享契約、資料模型或公共入口改動可能波及其他模塊時，才按實際依賴擴大日常驗證範圍。已通過的未受影響項不為增加測試次數而重跑。
- 真實 API／站點與 UI 以受影響路徑的實際運行驗證另記，不把易變網站放入必過離線套件；純 UI 改動優先實際面板／視窗操作，沒有相關既有測試失效時不另外堆測試。減少自動化項目不能以 mock 或未執行聲明代替必要的真實登入／播放／下載證據。
- 沒有現成測試 target 時，只建立承載必要行為的最小入口；沿用現有 fixture、runner 與構建產物，不另造通用測試平台、額外 target 或重複測試矩陣。
- 結案逐項記錄：需求／工作包、改動位置、執行命令、資料樣本（去敏）、觀察結果、截圖／產物、未驗證及受阻項。狀態只有未開始、進行中、受阻、已驗收；「已編譯」不是「已驗收」。
- W10 完成前，受影響呼叫端、資料模型、測試、設定、README 與工作記錄全部同步；移除臨時驗證腳本及過時路徑。

<a id="plan-risks"></a>
## 9. 風險與決策關卡

| 風險 | 決策與處理時機 |
| --- | --- |
| 全配置來源演變成另一門程式語言 | W3 以兩站共同需求限定規則；不適配者走原生，不擴張任意腳本能力 |
| Bangumi 與來源作品／集數錯配 | W1 固定身份及關聯契約；W4 不以同名或相同下標自動綁定 |
| 外部播放器缺少可靠觀看事件 | 本階段不做自動已看或雙向觀看進度同步，播放成功不等於看完 |
| HLS 封裝、續傳與打包比進度頁複雜 | W6 先用真實媒體證明下載引擎及產物，再完成 UI；不可只交任務外觀 |
| 網站登入依賴共用 Cookie | W2 先驗證帳號隔離，W7 再驗證真實任務串接；不能僅添加帳號選單 |
| 高自由度損害可用性 | W8 保證固定恢復入口、穩定實例、原生焦點及可逆編輯；Skin／Layout 不更改業務規則，W9 按 §6.5 量測操作旅程 |
| 不可信 Skin／腳本取得權限或阻塞 App | W8.2 做包／素材邊界及原子套用；W8.3 證明 helper 權限、記憶體與可終止執行；未證明不得開放腳本匯入 |
| 內部重構破壞共享 Skin | 穩定語義 typeID／樣式槽、文件版本與副本遷移，不序列化程式類名、不相容時明示拒絕 |
| 分享洩漏私人資料或侵犯素材授權 | 允許清單匯出、乾淨 profile 重匯入、保留作者／來源／素材授權；不把宣告作者視為已驗證身份 |
| 新舊 UI 長期並存、資料遷移失敗 | W0 留基線及資料副本；每入口切換後移除舊路徑，W10 查工程與資源引用 |
| Torrent 稀疏檔誤讀、共享任務誤刪或最低系統不符 | W11 用校驗完成的 pieces 提供 Range；reader／下載分開持有使用權；先建置固定 2.1.2 並驗證 macOS 13.5，再於 MT3 簽收，不以選型煙霧代驗 |

### 9.1 未簽收關卡與待定技術條件

下表彙整既有缺口，不因恢復驗收自動簽收；目前依 §0.2／§5.5 執行，缺環境或授權的項目分別列為受阻。

| 項目 | 責任範圍 | 必須確定／證明的內容 |
| --- | --- | --- |
| 原 M2／W2 | §5.1／§5.2、[A.2](#a-w2)／[A.7](#a-w7) | 有效雙帳號、重新授權及有效帳號下載等原缺口；保留使用者已確認項，不用 guest／fixture 替代 |
| 功能能力與依賴清單 | W8.1 已定案 | 見 §5.3.1／WorkspaceCapability；七種組件可重複、可停用能力及活動任務阻擋已實作，完整產品旅程仍未簽收，見 [R7 集中結果／受阻報告](#r7-acceptance) |
| Skin／素材資源上限 | W8.2 已定案並驗證 | 具體值及最大合法包／越界證據見 §5.3.2；W8.4 編輯與預覽沿用同一驗證器，不另放寬 |
| 腳本引擎與 helper 限制 | W8.3 | macOS 13.5、簽署／sandbox、權限、記憶體限制及真正可終止執行；未證明前不開放外部腳本 |
| 最低系統與獨立發佈 | W10／W11.4、PROJECT | Intel 實機、最低 macOS、依賴／授權、簽署／公證及 fork 身分；缺少環境明示未驗證 |

<a id="history"></a>
## 附錄 A. 歷史交付與驗收證據

本附錄保留原記錄的日期、樣本、命令、數據、失敗與未驗證範圍，不是目前執行清單。舊符號（如 Processes.shared）及「當時未開始」描述只代表記錄時點；現行組裝及狀態以 §0／§2 為準。過去實播證據不代替當前正式產品驗收，也不擴大未簽收項。

W0 獨立證據見 [FRONTEND_W0_BASELINE.md](FRONTEND_W0_BASELINE.md)；依時間記錄的後續修復見 [WORK_LOG.md](../history/WORK_LOG.md)。

<a id="a-w1"></a>
### A.1 W1 驗收記錄（2026-10-07）

- 身份：`WorkLibrary.swift` 提供真實 Core Data 寫入／查詢；作品、集數、來源關聯使用穩定 UUID，同名作品不合併，正篇／SP／第 0 集不以索引互換。來源映射明確引用本機 Episode ID 與 `SourceItemRef`，拒絕跨作品、重複及來源不一致的映射；元資料更新保留已確認關聯。
- 選擇：`SourceSelection.swift` 保存來源 ID、規範頁面、種類、集數／分 P、品質與備援線路，不保存短效媒體 URL。`qualityID` 是既有 stream key；`lineID` 是同一 stream 的主／備援槽位（0 主址、1 第一個備援），動漫來源既有命名線路仍是 stream key。W2 前非空 `accountID` 明示不支援，不能默默忽略或冒充帳號隔離。
- 服務：`VideoDecoder` 集中規範 URL、目錄、解析及品質準備；Main／書籤／B 站動態選集、HTTP、JSPlayer、OpenFiles 全部改走共用選擇／解析入口。`Processes` 只擁有主視窗搜尋 Task，主 UI 以 request ID 拒絕舊結果；HTTP 和已啟動的播放不受搜尋取消影響。原 HTTP JSON／URL scheme 邊界不變。
- 模型：`Library v0.4` 新增三個持久實體，既有 Bookmark 欄位不變；保留所有來源模型，啟用自動／推斷遷移。僅對沒有 `order` 的來源模型初始化排序，已有 v0.3 分數排序不重寫。這不是 W5 收藏雙欄遷移。
- 還原：舊 App 不能直接打開 v0.4 store；回退須先退出 App，再還原遷移前一致的 SQLite／WAL／SHM 備份或 SQLite backup 產物。不能只降 `.xccurrentversion`。本次僅操作隔離及臨時 store，使用者資料不遷移。

| 驗收項 | 已執行證據 |
| --- | --- |
| 保存、重開、映射及模型演進 | `Tests/run-work-library.sh` 編譯實際生產型別及 Core Data 模型；SQLite 重開、同名不同作品、正篇／SP／第 0 集、映射／元資料更新及所有舊模型遷移通過 |
| 共用服務與取消 | 真實 App 模組運行 URL 規範／分 P、保存後重新解析指定集、品質／備援選擇、無效選擇拒絕、取消／替換及獨立播放；實際 OpenFiles storyboard／controller 的本機檔與無效輸入通過 |
| 既有介面及媒體 | 最終 Debug arm64 建置；隔離 App 的 Fqdm 目錄由 SP 後選正篇，回寫正確集數 URL 並取得品質；雙擊品質經 `Processes` 啟動真實 libmpv runner，媒體前進並銷毀；另保存實際影片畫面 |
| HTTP 相容 | 實際 App 的 b23、普通影片／集數、normal IINA scheme 與有效 percent-encoded 指定品質回 200；缺參數／不支援回 400；JSON 仍為既有五個頂層欄位 |

去敏文字、建置與 PNG 保存於 `.build/w1/evidence/`；永久離線行為測試位於 `Tests/Library/WorkLibraryRegression.swift`。臨時 runner 使用安裝版 IINA 的 libmpv，不等同官方 mpv CLI 或 IINA 視窗版本相容驗收。全部來源／線路、JSPlayer 直播、完整彈幕生命週期、macOS 13.5 與正式發佈未在 W1 全面回歸；W1 結案時 W2–W10 與新 UI 尚未實作。

<a id="a-w2"></a>
### A.2 W2 實作與驗證記錄（2026-10-07）

**實作已交付；不把以下隔離／負向驗證冒充兩個真實帳號已完成授權。** 第 4.1 節的真實雙帳號請求身份及失效後重新授權，仍需使用者在現有登入視窗完成平台授權，尚未簽收。

2026-10-08 補充：使用者已確認 W2 的 Douyu 帳號正常工作，採納該驗收，不重跑真實登入。此確認不推定兩個真實帳號／Bilibili／失效後重新授權都已驗收。Bangumi 帳號擴展與驗證見 W4 記錄。

- `Preferences` 沿用 UserDefaults，保存來源啟停／預設帳號及既有播放器、品質、彈幕偏好；下載目錄保存 security-scoped bookmark 與路徑，併發數限制為 1–8。`downloadPolicySnapshot()` 複製新任務的目錄、併發及暫存位置，不搬動現有檔案。
- `SiteAccounts` actor 管理 Bilibili／Douyu 號池的新增、選預設、停用、移除、本機登出、重新登入與有效性刷新；Bangumi 使用單一個人帳號 OAuth，見 W4 記錄。Bilibili 影片與直播共用帳號，直播可另選預設。一般偏好只存 UUID／名稱／狀態；Cookie 按帳號 UUID 存 Keychain，舊 Cookie 安全複製成功後才刪除同站舊值，匯入不假設登入有效。
- `LoginWebView` 每次登入使用新的非持久 WKWebsiteDataStore；現有 Bili／Douyu sheet 及 legacy Bili controller 共用服務。Cookie 名稱只是檢查時機；Bili 使用 nav，Douyu 使用官方主站 `/lapi/member/api/getInfo`，要求 error=0、正值伺服器 UID 與登入 Cookie UID 一致，才提交憑證。取消不選預設、不提交憑證。無舊憑證可遷移時不開啟全域 WebKit Cookie store。
- Bili／Douyu HTTP、動態與彈幕初始化改用同一帳號上下文／ephemeral Session；Bili WBI 快取按帳號分開。解析、品質及點播彈幕沿用捕獲的 `PlayableSelection.accountID`，已保存的 nil 表示 guest，不因新預設改變身份，也不輪換帳號。失效／停用／無效帳號有明確錯誤。本機登出只刪此帳號憑證與預設引用，不撤銷平台或其他裝置會話。
- `acquireUse`／`releaseUse` 以不可重複釋放的 lease token 表示使用；停用、移除、登出及重新登入提交拒絕其他使用者持有的 lease。W6 必須讓任務從開始到結束持有 lease，停止任務後釋放；W2 沒有真實下載任務。
- `ImageCacheService` 只管理 App-owned 封面／表情、元資料、下載暫存及完成檔區；清理／按修改時間淘汰只作用於前兩者，預設上限 512 MiB，不跟隨符號連結。SDWebImage 在首次建立 shared cache 前改用 owned 路徑，啟動時套用上限及淘汰；現有 Advanced 的大小／Clear 按鈕使用同一服務，不清全域 WebKit 資料。完成檔區的 filesystem 數字不是 W6 任務清單或任意 Downloads 目錄的統計。

| 驗證項 | 已執行證據 |
| --- | --- |
| 建置及持久化 | 最終 Debug arm64 xcodebuild 成功；`Tests/run-w2-services.sh` 連結生產 App 模組，來源／預設帳號、播放偏好及不可變下載策略重讀通過；W1 全部舊 Core Data 模型遷移／重開回歸仍通過 |
| 安全儲存及帳號生命週期 | 真實 Keychain 的兩組同站合成憑證不互蓋；copy-before-delete、重啟、另一帳號登出／移除、使用中拒絕及重複 release 不釋放別人的 lease 通過。valid metadata 只用於離線 lease 契約，未假稱平台授權 |
| 登入容器及失敗處理 | 變更前兩個生產 LoginWebView 共用 store；變更後實際掛載的兩個容器 Cookie 分離，取消後不提交／不改 guest；Bili／Douyu 真實服務均拒絕無效 Cookie。兩站登入頁有 WK snapshot，QR 已遮蔽 |
| 選擇及來源啟停 | 生產 decoder 的保存 guest 在新增預設後仍到達真實來源；已刪除影片回來源錯誤而非採用新帳號。新選擇需授權而非 fallback，停用拒絕新解析；實際 App 的有效本機媒體 URL HTTP 回 200，JSON 邊界保留 |
| 快取及現有入口 | 真實 filesystem 計量、上限、淘汰、符號連結與清理保護回歸通過；實際 Advanced 按鈕以原生輸入清零封面／元資料，下載暫存及完成檔 fixture 保留，介面大小更新為 0.00 MB |

證據位於 `.build/w2/evidence/`；永久測試為 `PreferencesRegression`、`SiteAccountsRegression`、`CacheServiceRegression`。原生驗證 host 掛載當次建置的真實 view／controller，不是新產品頁面；視窗內容／WebView snapshot 不冒充完整桌面螢幕擷取。未使用使用者原 profile 或真實憑證。兩個真實帳號的伺服器 UID／Cookie 身份及重新授權成功仍待人工驗收；真實下載／目錄策略與清理、完整彈幕生命週期、全部播放器、最低 macOS 13.5 及發佈仍按 W6／W7／W10 驗收。

<a id="a-w3"></a>
### A.3 W3 驗收記錄與來源能力矩陣（2026-10-08）

**第 4.2 節已驗收；能力接入不等於所有遠端樣本均可播放。** 新增 `SourceRegistry`、`SourceConfiguration`、`ConfiguredSource` 與 `SourceCapabilities`。原生來源由 registry 分類／能力檢查後分派，B23 展開、Bilibili 影片／番劇／直播、房間／主題列表及代理仍由原生適配器處理。配置來源使用 `.configured(id)`，不再增加 enum、UI switch 或原生站點類別；Fqdm／Forest 的舊 actor 已刪除。

配置與操作：

- 內建規則是 `IINA+/Sources/fqdm.json`、`forest.json`，以 `Sources` 資料夾資源打包。使用者規則位於 `~/Library/Application Support/<CFBundleIdentifier>/sources/*.json`；現有工程 ID 為 `com.xjbeta.iina-plus`。啟動時載入；程式端 `try SourceRegistry.shared.reload()` 可立即重載，也可重啟 App 載入。未增加 W9 的來源設定／重載頁面。
- 重載原子替換 immutable snapshot；同 ID、既有原生 ID 或 host 重疊皆明示拋錯，不覆蓋內建來源。失敗保留最後可用 snapshot／錯誤；首次啟動遇到壞使用者配置仍保留有效內建與原生來源。停用來源阻止新操作，但不改既有書籤的來源身份。
- schema `version: 1`，必需 `id/name/hosts/capabilities/route/catalog/player`；`route.pattern` 及 capture 指定 ID／線路／集數，支援正整數 ID 規範化及指定 query 集數身份。`catalog`、`search` 是 GET HTML selector 或 JSON dotted path；`player` 是公開媒體模板或固定 payload 提取，僅有 MacCMS 0/1/2 URL 解碼等有限轉換，無任意 JS／腳本 DSL。JSON payload path 不當成 HTML regex。
- 靜態模板禁止內嵌 Cookie／token／Authorization，未知欄位、缺欄位及不支援版本／能力拒絕。頁面 host 精確比對，拒絕 userinfo／顯式 port；請求與重導向重新檢查 HTTPS／目的主機。`credentialHosts` 只能是來源 host 的子集，憑證按捕獲的帳號上下文及目的 host 重新授權；未授權目的地不帶 Cookie／Authorization，沒有共享 Cookie jar。允許無來源憑證的公開 HTTPS CDN／簽名媒體，不把動態公開簽名誤判為配置內嵌憑證。
- `Tests/Fixtures/Sources/internet-archive.json` 是未打包的第三站範例；僅複製 JSON 到使用者 sources 並 reload。metadata/files 提取公開 MP4，`file` query 保持選檔身份；搜尋指定 identifier 排序，避免服務端預設相關性排序造成跨頁重複。`VideoDecoder.searchSource(sourceID:query:page:)` 回傳來源引用／下一頁，未增加 W7 搜尋聚合或 W9 頁面。

| 驗證項 | 已執行證據 |
| --- | --- |
| 生產建置與回歸 | Debug arm64 xcodebuild 成功；`Tests/run-w3-sources.sh` 連結生產模組，URL／payload 安全、版本／衝突／最後可用 snapshot、停用／移除、檔案身份、跨線路同集數及 JSON player 路徑通過；W2 與 WorkLibrary 全部既有 runner 通過 |
| 兩站原生→配置 | Fqdm 海贼王：5917 葉節點／5 線；Forest 完美世界：847 葉節點／3 線。逐一比對遷移前後 title、完整 URL／label／分組順序、current 及 stream key／index，全部相同；不是只比數量 |
| 第三站純配置 | 編譯臨時程式後才加入 Internet Archive JSON；reload 後 metadata→選 MP4→保存／重讀選擇→再解析，來源／檔案身份不變。真實搜尋兩頁各 20 筆、下一頁及不重複身份通過；Girigiri 原生選集與配置引擎共用入口，臨時 native decoder 可釋放 |
| 真實播放／現有介面 | CC-BY 3.0 Big Buck Bunny：`Processes.openWithPlayer` 啟動 libmpv 視窗，416×240、time-pos 3.125 秒並停止／destroy。另在隔離原生 App 搜尋輸入該 URL，回寫選檔 query／顯示 `Line 1 (1)`，雙擊後再次取得實際影格、time-pos 3.0416667 秒及 stop／destroy 證據 |

#### W3 逐來源能力及現場結果

✓ 表示已有對應入口／適配器，不是所有資料、線路或播放器均通過；— 表示當時未接入／入口拒絕。本表搜尋欄保留 W3 現場狀態；W7 已接入 css1.json 的 17 個既有來源及 Bilibili 搜尋，當前實測見 §5.2。直播「選集」是房間／主題；CMS 線路不冒充解析度品質。IINA／mpv 欄是協議接入，libmpv 證據不等於其應用版本相容驗收；browse 仍未接入。下載 ✓* 僅代表原選擇實際解析成受支援直連／有限非 DRM HLS 的點播；W7 額外允許 Didahd 精確匹配的未過期 owned PNG→TS 代理，仍拒絕任意 loopback、直播、DASH 分離及 local，不推定每條遠端線路可下載。

2026-10-08 後續來源修復已更新下列稀飯、嘀嗒、E-ACG、森之屋、櫻花、Hanime 行，並新增熱播；詳見 `docs/research/websitesforanime.md` 及工作記錄。本輪使用生產模組、FFmpeg 及無視窗 libmpv，不混同 W3 的視窗證據；其餘行仍為原 W3 現場紀錄。

| source ID | 搜尋 | 解析 | 選集 | 線路 | 品質 | IINA | mpv | JSPlayer | 彈幕 | 下載 | 本次現場結果 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| bilibili | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | ✓ | — | BV 樣本及 B23 展開取得品質；番劇原生頁面限制另記錄 |
| bilibili-live | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | 直播房間取得超清／高清 |
| douyu | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | 樣本取得原畫 |
| huya | — | ✓ | ✓ | — | ✓ | ✓ | ✓ | ✓ | ✓ | — | 取得五檔本機代理 URL；本次未播代理 |
| cc163 | — | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | — | — | inspection：MarshalError；未判因，未宣稱修復 |
| douyin | — | ✓ | — | — | ✓ | ✓ | ✓ | ✓ | ✓ | — | inspection：CookiesError；本次 guest 未完成解析 |
| qie-tv | — | ✓ | — | — | — | ✓ | ✓ | ✓ | ✓ | — | 取得 Default 流 |
| xifan | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 2026-10-08 修復站方播放器配置及 AES-CBC 取址；1477 第 1／2 集經建置 App 完整入口取得真實 MP4，libmpv 解碼 1920×1080 並播放超過 2 秒。原生 IINA 遇本機外掛缺失，應用視窗未驗收；新番部分播放頁仍有站方資料庫 DNS 錯誤／逾時 |
| girigiri | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得简中流；同入口共存通過 |
| didahd | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | W3 修復 /rc/ 路徑，3071 第 7 線第 1 集經 PNG→TS 代理解碼；W7 接入 owned 代理下載，實際 379／552 段後 mediaUnavailable，未宣稱完成 |
| jibi | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得五線 |
| eacg | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 現行 Comicplay／voddetails 路由及伺服器線路 ID 已修復；69000 五線 FFmpeg 通過，所選第 3 線第 2 集保留且 libmpv 可播 |
| senfun | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 修復電影 hd slug；2025261963 三線 FFmpeg 通過，首線 libmpv 可播 |
| kanba | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得五線；遠端線序會變化 |
| haixing | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得六線 |
| yinghua | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 新 yinghuabb 網域及所選線路優先已修復；79473 六線 FFmpeg 通過，所選 sid=7 libmpv 可播；sid=1 媒體解碼失敗 |
| dilidili | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | inspection：notFountData，未判因 |
| youknow | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得多線 |
| fqdm | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 配置化；5917 葉節點及五線結果與基準一致 |
| hanime1 | — | ✓ | — | — | ✓ | ✓ | ✓ | — | — | ✓* | 修復 h3／meta 標題；408446 的 1080p／720p／480p FFmpeg 通過，1080p libmpv 可播 |
| wedm | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得三線 |
| forest | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 配置化；847 葉節點及三線結果與基準一致 |
| fengche | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 原生來源取得七線；不冒充各線媒體通過 |
| rebo | — | ✓ | ✓ | ✓ | — | ✓ | ✓ | — | — | ✓* | 新增公開 BBA／NBY encrypt=3 站方播放器取址；3832 的 sid=4／5 FFmpeg 與 libmpv 通過，取消後可再解析；BBA 曾出現媒體失敗／逾時，網盤及受限線路不接入 |
| local | — | ✓ | — | — | — | ✓ | ✓ | — | ✓ | — | 本機引用／身份辨識通過；本次未建立或播放本機檔 |
| internet-archive | ✓ | ✓ | ✓ | — | — | ✓ | ✓ | — | — | ✓* | 僅新增使用者配置；搜尋／選檔／實際播放通過 |

證據保存於 `.build/w3/evidence/`：`before.json`／`after.txt`、`source-matrix.json`、`native-variants*.json`／`bangumi-native.json`、生產建置及三組 runner 日誌、`app-archive-catalog.png`、`archive-player-{registry,app}.{json,png}`。番劇 ss959 的原生直解本次回 NSCocoaErrorDomain 3840，頁面未提取到 playInfo；未宣稱修復其現行 HTML／播放 JSON 解析。除配置兩站外，原生解析器不因此次遷移修改遠端協議；失敗按現場階段／錯誤記錄，不全歸因於網路，也不把「有媒體 URL」冒充播放驗收。完整彈幕生命週期、其他播放器、macOS 13.5 與發佈未全面回歸；W2 真實雙帳號／重新授權門檻不因 W3 完成而消失。隔離 App 使用獨立 Bundle ID／home，使用者資料及既有 IINA 不動；臨時 runner／profile／App 複本結案清除。

<a id="a-w4"></a>
### A.4 W4 驗收記錄與 Bangumi 帳號接入（2026-10-08）

**第 4.3 節已驗收。** 基礎服務與既有 Sites 的必要授權入口已交付；搜尋／作品／發現新頁面仍屬 W7–W9，不在本次提前製作。

- 官方契約：接入時查核 [Bangumi 官方 API](https://bangumi.github.io/api/) 及現場回應。搜尋使用 `POST /v0/search/subjects` 的 keyword／limit／offset；作品使用 `GET /v0/subjects/{id}` 的 name、name_cn、date、type、platform、images、summary、infobox、eps、total_episodes；集數使用 `GET /v0/episodes?subject_id=…` 並取得所有類型與全部分頁，不把 SP／OP／ED 當正篇。`GET /calendar` 是舊版根路徑，日期／總集數欄位兼容該排期的 air_date／eps_count。0 集數視為未知，不偽造總量；資料來源 URL 與 fetchedAt 保留。
- 用例：`BangumiService.search`、`metadata(forceRefresh:)`、`calendar(forceRefresh:)`；24 小時內可直接讀取 owned metadata cache，手動刷新繞過本機期限（官方作品端仍可能有 300 秒伺服器快取）。快取按 Bangumi 帳號 UUID／guest 分開，使用開始時捕獲的預設帳號，不輪換。寫入後使用 W2 的上限淘汰；斷網回傳 `staleCache`、原取得時間及具體失敗，取消不轉成空資料或舊結果。
- 本機作品：`Work.bangumiMetadata` 獨立保存外部快照，現有 title／aliases／coverURL／year／summary 保留為本機欄位；Core Data v0.4 的 JSON payload 演進，不改模型或書籤排序。`WorkLibrary.createLocalWork` 不按名稱合併；`setBangumiAssociation` 選擇／解除關聯；`BangumiWorkSync.associate`／`refresh` 保存實際資料。解除／更換只清外部快照，不刪本機 Work／Episode／SourceLink 或重建 UUID。關聯 revision 拒絕 A→B→A 期間的舊回應；外部集數不按下標自動覆盖已確認的本機集數映射。
- 排程入口：`BangumiWorkSync.refreshFavorites(workIDs:forceRefresh:accountID:)` 逐作品去重並回報各項失敗；W5 提供真實收藏 ID，W7 串接啟動／跨日。無關聯回傳 `unlinked`；已關聯但尚未取得資料為 `linkedWithoutMetadata`。已保存的外部快照不屬可重建快取，清理／淘汰後仍可离線讀取，不把資料服務故障傳到來源播放。
- 帳號：來源 ID `bangumi` 僅代表元資料帳號，不是既有 Bilibili 番劇或新影音來源。採用官方 [OAuth 授權碼流程](https://github.com/bangumi/api/blob/master/docs-raw/How-to-Auth.md)，應用憑證由程式隱式處理，固定回調 `iina-ani://bangumi/oauth` 在非持久 WebView 內攔截並核對 state／目的地。Settings → Sites → Bangumi 只有登入／重新授權、刷新及登出，移除手貼 token、安全輸入欄位、號池／選帳號／啟停／預設／移除帳號控制。`GET /v0/me` 驗證後才將 access token／refresh token／到期時間一併存 Keychain；Refresh 可續期，失敗保留舊憑證；有效個人帳號自動供元資料請求使用。Bearer 仍僅送 HTTPS api.bgm.tv 的標準埠，跨站／降級逐次去除授權；一般偏好／日誌不存 token。lease 阻止使用中換憑證，取消在提交前再次檢查。單帳號 UUID 保存在非秘密偏好，遷移沿用原預設／首筆，保留但不啟用其他舊憑證；登出刪兩種 token 並換新身份，重啟不切到舊帳號，避免下一次登入沿用上一個身份的私有快取。內置 app secret 可被提取，不宣稱具備伺服器端保密性。

| 驗證項 | 已執行證據 |
| --- | --- |
| 建置與回歸 | 最終 Debug arm64 xcodebuild 成功；`run-work-library.sh`、`run-w4-bangumi.sh`、`run-w2-services.sh`、`run-w3-sources.sh` 通過。覆蓋實際 Core Data 重開／舊模型、外部欄位與本機欄位隔離、同名身份、關聯切換、分頁、快取期限／強刷、未知總量、取消及局部失敗 |
| 真實 API | 生產模組取得《葬送的芙莉蓮》ID 400602：日期 2023-09-29、封面／簡介／別名及 36 筆所有類型集數；作品搜尋 total=90，第二頁 offset=10；七天排期有原取得時間。另一真實作品關聯→解除→重新關聯後本機 UUID／來源映射不變；真實無效 PAT 被拒絕且不寫 Keychain／預設 |
| 重啟與離線 | 第二個獨立程序重開真實 API 產生的 SQLite／磁碟快取；注入 notConnectedToInternet 模擬斷網，回傳快取及原 fetchedAt。清空 owned cache 後，已保存的 Work 外部快照與來源映射仍可讀；未改變系統網路狀態 |
| 初版帳號與原生入口（PAT，現已替換） | 真實 Keychain 的合成帳號隔離、成功／失敗重新授權的替換／保留、lease、取消提交與預設清理回歸通過。當時的獨立 Bundle ID／home 驗證副本以原生 AX 操作新增帳號→安全輸入→真實 401→移除；記錄僅代表初版 PAT 入口，不代表現行 OAuth 單帳號介面 |

初版證據位於 `.build/w4/evidence/`（online／offline、build、四組 runner、Sites／Bangumi PNG）。未以合成憑證冒充有效個人授權，未新增收藏／搜尋／發現產品頁、觀看進度同步、真實下載或播放器驗收。

同日 OAuth／單帳號修正：Debug arm64 建置與 W2／W4 runner 通過，新增 state／固定回調、拒絕與取消、重新授權保留／替換、續期、單帳號遷移及登出後快取身份隔離回歸。生產 OAuth 程式連到真實 token 端點，無效 code 得到 HTTP 400 `invalid_grant`，不提交帳號；原生 App 的獨立驗證副本實際顯示無號池控制的單帳號頁、開啟官方個人登入頁、取消後仍未授權，PNG／去敏記錄見 `.build/bangumi-oauth-smoke/evidence/`。完整有效個人登入／同意授權與真實 refresh token 續期尚未驗收，不以離線 fixture 取代。

2026-10-09 回調丟參修正：使用者仍收到 `invalid_uri / No redirect URI was supplied or stored`。現場發現未登入時 `/oauth/authorize` 生成的 login 返回地址省略 `redirect_uri`；直接登入但未完全編碼的巢狀 query 亦會被截斷。現改先走 `/login`，以雙層完整百分號編碼的 `chii_referer` 傳遞授權請求。生產 `BangumiOAuth.Attempt.loginURL` 於原生 WKWebView 實際載入官方頁，表單提交的 `referer` 完整保留固定回調及本次 state；最終 App 的獨立副本實測個人登入頁與取消。Debug、W2／W4 回歸通過，證據見 `.build/bangumi-redirect-fix/evidence/`。此次驗證登入返回地址，而非只驗證打開登入頁或無效 code 回應；未宣稱已取得真實有效 code／個人 token。

<a id="a-w5"></a>
### A.5 W5 驗收記錄（2026-10-09）

`FavoriteLibrary` 統一收藏命令；既有 DataManager 的新增／查詢／移動／刪除書籤已切換，沒有第二份連結儲存。Core Data v0.5 在 Bookmark 增加 UUID、原 URL、canonical URL、來源、獨立標題與建立時間；WorkFavoriteRecord 只保存 Work UUID、排序及收藏時間，Bangumi／來源／集數仍由 WorkLibrary 擁有。手動來源命令確認 Work 關聯，不猜測同名作品，也不將單集、直播或普通影片自動提升為作品。

| 驗證項 | 已執行證據 |
| --- | --- |
| 作品收藏與多來源 | 同 Work UUID 重複加入僅一筆；同標題或同 Bangumi ID 的不同本機 Work 不合併；兩個明確來源關聯保存重讀。實際收藏 UUID 已交給 BangumiWorkSync，無 Bangumi 關聯時回傳 unlinked，不捏造元資料 |
| 連結身份 | 生產 SourceRegistry 與 VideoDecoder 共用頁面 identity；實測 Bili tracking／p=1、p=2、festival 的分 P 與配置來源 query。原 URL 保留，未知／失效連結可離線編輯；編輯碰撞拒絕且原記錄不變。b23 離線保留短鏈身份，不推定已與長鏈去重 |
| 獨立操作與刪除隔離 | 兩類查詢／排序／移動／刪除互不影響；取消作品收藏保留 Work、Episode、WorkSourceLink／EpisodeSourceMap。兩個獨立程序完成保存、重開、編輯與刪除，完成媒體檔及獨立帳號資料 fixture 位元組不變；不是 W6 真實任務／有效憑證驗收 |
| 舊庫與還原 | v0.3／v0.4 實際 SQLite（包括尚未 checkpoint 的 WAL）在 schema 升級前備份；原 URL、liveTitle、remark、Double 排序與重複列全保留。新加入按遷移 identity 去重；重複啟動不再建立身份。關閉 coordinator 後還原、以舊 model 重讀並重新遷移；開庫還原被拒絕 |
| 失敗與版本 | 真實 SQLite trigger 強制 save 失敗，原列及完成標記回滾，備份不覆蓋；去掉故障後可再遷移。無效備份原樣保留；未來 migration version 不降級。空庫版本亦立即持久保存，不靠後續寫入或假 bookmark |
| 執行證據 | Debug arm64 建置、WorkLibrary、W2／W3／W4 與公開 W5 runner 通過；獨立 Bundle ID／home 的原生 App 載入舊庫副本，實際顯示普通影片、分 P、直播、劇集及失效網址。兩次 App 開庫後 5 筆 UUID／標題／原 URL／小數排序／版本完全一致；沒有使用者現用庫的修改 |
| 原生新增與標題 | AX 真實操作 Add sheet，初次驗證發現遠端刷新前空行；收藏建立補齊原有 AppKit 綁定的 cache 字段。最終 App 的生產 MainViewController／AddBookmarkViewController 保存 p=2／p=3、dismiss sheet、離線重讀成功；刷新前實際 NSView render 顯示 p=3 網址而非空行，刷新後仍可顯示實際 Bili 元資料 |

證據保留於 `.build/w5/evidence/`；回歸入口 `bash Tests/run-w5-favorites.sh`。最後副本的 NSWindow 未出現在 WindowServer／AX 的視窗列舉中，故最終新增由 debugger 操作實際 controller／text field／IBAction，視覺證據為該 App 真實 NSView 的 cacheDisplay render，不冒充桌面截圖；舊庫介面保留正常 window screenshot。備份位置／冷還原 API 與回退丟棄備份後修改的風險見 README「收藏與舊書籤遷移」。未驗證最低 macOS，未交付雙欄 View、可調欄寬、完整搜尋／收藏串接或真實下載；分別仍屬 W9、W7、W6。

<a id="a-w6"></a>
### A.6 W6 驗收記錄（2026-10-09）

**第 4.5 節已驗收。** `DownloadService` 是唯一任務 owner；`Processes.shared.downloads()` 建立／查詢任務及訂閱事件，`openDownloadedFile` 沿用原播放器命令。沒有新增 W9 的下載頁、Finder 按鈕或詳情頁依賴。

- `DownloadSourceResolver` 每次按原 `PlayableSelection` 解析精確集數／線路／品質及帳號，guest 不套用新預設；不支援的來源在建立前拒絕。CMS／Hanime1、Fqdm／Forest 與配置 Internet Archive 只對實際受支援直連／有限 HLS 開放下載，能力矩陣 ✓* 不推定所有遠端媒體可用。直播、DRM、分离 DASH、Didahd 代理與 local 不開放。
- 直連串流寫入，strong ETag／原 URL hash／Content-Range 身份一致才續傳；簽名 URL 更新或不支援 Range 明示重新下載。HLS 順序下載 TS／fMP4、MAP、BYTERANGE、AES-128／IV 及分離音訊；主清單保留最初最高 BANDWIDTH 的變體身份，不可在恢復時替換。HLS 重新下載全部分段，不拼接無法驗證的舊資料。
- 帳號 lease、快取清理與捕獲的目錄／bookmark／併發策略串接；預設 2 項。私有 JSON 原子保存及 writer lock，重開將中斷工作轉 `paused`／`needsRecovery`，正常退出等待 writer 停止。暫停保留 lease，結束／失敗／取消釋放；封裝階段不允許暫停／取消。刪記錄與刪完成檔分離，exclusive rename 不覆寫、長 Unicode 標題使用有效檔名。
- 進度是實際媒體 bytes／分段與可得速度／ETA，未知總量保持未知；完成數據取 writer 的最終結果，不依赖被節流／延後的回呼，也不把封裝後檔案大小當成傳輸量。FFmpeg 在單一 utility 執行緒啟動／讀 stderr／等待，避免實際觀察到的 Foundation 跨執行緒退出等待卡住。

| 公開完成檔 | 檔案 bytes | 解碼尺寸 | 時長（秒） | 尾段 time-pos（秒） |
| --- | --- | --- | --- | --- |
| Internet Archive Big Buck Bunny MP4 | 43,315,070 | 416×240 | 596.4167 | 593.9583 |
| Mux test_001 完整有限 HLS → MKV | 59,822,400 | 640×360 | 510 | 507.52 |

公開直連經純配置／生產解析器建立任務；HLS 基線以公開 Mux manifest 交給真實任務／傳輸／封裝，完整清單不截短。兩檔均透過 `Processes.openDownloadedFile` 啟動實際 libmpv helper、播放超過一秒、seek 到尾段再播放並 destroy；是無視窗解碼證據，不冒充 IINA 應用或官方 mpv CLI 視窗相容驗收。EACG 原選第 3 線第 2 集下載 239 段後網路中斷並回 `network`，未宣稱該集完成或偷偷替換其來源。
最終公開 HLS 再次驗證完整 51 段、67,321,296 媒體傳輸 bytes，封裝前後進度一致；新完成檔亦經同一開啟 API 通過解碼／尾段。EACG 的失敗任務另以生產解析器重新解析原集數／線路／品質／guest，重新取得 HLS key 後暫停／取消並清理暫存，沒有更換成 Mux 任務。

- 最終 Debug arm64 建置與 `bash Tests/run-w6-downloads.sh` 通過：精確 Range／ETag、未知總量、重定向 Cookie 邊界、暫停／取消、帳號 lease、偏好快照、401 後重新解析／內容一致、刪除隔離、檔名衝突／Unicode、真正獨立程序強制／正常退出及重開恢復。真實 FFmpeg 產生 AES 非零序號／implicit IV、fMP4 MAP、implicit BYTERANGE、主清單分離音視訊；FFprobe 驗證音視軌，主變體消失拒絕降級，最終傳輸量／全部段數另有服務回歸。
- 真實文件系統 smoke：24 MiB HFS+ 磁碟映像下載 32 MiB 到不足空間，正確 `diskFull`；系統唯讀路徑回 `directoryNotWritable`。清除可重建快取保留實際 writer；檔名碰撞保留原檔並發佈不同檔案。公開 HLS 暫停／重新開始及封裝時拒絕取消亦實際運行。
- 記錄／完成媒體／播放器 JSON 與去敏日誌留於 `.build/w6/evidence/`；成熟封裝工具的搜尋位置、缺少 FFmpeg 錯誤、打包／架構／最低系統及 LGPL／GPL 要求見 README。未捆綁 Homebrew binary，未驗證 macOS 13.5 或正式發佈；帳號 lease／401 fixture 不冒充 W2 的有效雙帳號驗收。

<a id="a-w7"></a>
### A.7 W7 交付及 M2 對照（2026-10-09）

**本次指定範圍已交付；原 M2 帳號版關卡未全通過。** 使用者提供 css1.json 與 Bilibili 搜尋頁，並限定新增下載只做該清單。18 項合併 Hanime 兩檔後為 17 个既有來源；15 個原生搜尋加上 Fqdm／Forest 配置搜尋，Bilibili 額外搜尋、不新增下載。清單來源目前沒有網站帳號提供者，保存明確 guest；不製造登入或挪用 Bili／Douyu Cookie。既有 Internet Archive 使用者配置只作直連基線，沒有新增成內建站點。

- 搜尋 owner：`Processes.shared.browseSearch`；型別化 Bangumi／來源結果、來源種類與身份、來源篩選、固定查詢及獨立游標；空結果／失敗分離，失敗保留此前結果。URL 不依賴 Bangumi；新查詢／取消停止舊 worker 及底層傳輸，過時分頁不能回寫。
- 日常 owner：`AppDelegate.discovery()`；今日排期、收藏實際新增集、帶理由且待確認的當季同名候選。私有持久 seen 集合在可重建快取外；首次基線、重排、移除後再出現不冒充新集。啟動／前景／跨日刷新不輪詢，進行中跨日通知保留待刷新；固定日期與時區回歸驗證跨日、取消及分組／來源故障隔離。
- 來源修正：搜尋欄位通過完整嚴格配置載入；標題／連結分離、封面延遲屬性、已宣告下一頁、拒絕驗證頁，海星 pageindex 從 0 起但服務游標仍從 1 起。櫻花／熱播用現行已核對網域。Bilibili 使用非持久訪客 WebKit 官方前端 origin 的搜尋請求，不導入登入 Cookie；主頁僅容許 search.bilibili.com／www.bilibili.com 的 HTTPS，處理實際訪客跳轉並取消新視窗，既有 BV 解析、品質準備及播放器不另造分支。稀飯依站方 EcPlayer1.js 支援 type=auto 的同一 AES-CBC 契約，保留原集數／線路。

| 原 M2 項目 | 已執行證據／未簽收邊界 |
| --- | --- |
| 1 作品全鏈及重開 | 真實 Bangumi 400602 搜尋／資料，稀飯作品明確關聯、第二條備用線第 2 集；`resolve→prepareVideoUrl→openWithPlayer` 實際影格／尾段播放後收藏。第二程序重開 SQLite，Work UUID、元資料、Episode UUID、來源映射／品質／guest 不變，重新解析原選擇並再次播放 |
| 2 普通 URL／連結收藏 | 真實 Archive 普通影片 URL 在 Bangumi transport 強制離線時仍可解析、播放、收藏；第二程序重讀再播放。Bilibili 最後原生回歸首頁 20 筆，取消獨立查詢的底層 WebKit worker，第二頁累積 32 個不同身份；結果走同一普通 URL／既有準備鏈，實際影格／尾段後保存連結 |
| 3 指定帳號下載 | guest 直連及原稀飯 HLS 選擇已暫停、正常退出／第二程序重開、重新解析並完整下載／開啟完成檔；有效網站帳號版本未驗收，清單中沒有可用帳號提供者，沒有擴充 Bili／Douyu 下載 |
| 4 任務／偏好／快取／帳號 | 真實活動 HLS 時改目錄、清可重建快取，writer／暫存與已捕獲目錄保留，重开仍寫原目錄；使用中帳號拒絕移除由實際 DownloadService lease 回歸驗證，但不是有效網站帳號的人工驗收 |
| 5 日常資料 | 真實服務當日 14 筆排期、收藏初次基線 0 新增，推薦 0／無來源錯誤；相同日期重用持久基線。真實七天排期與當季有界樣本 122 筆另經 API 取得；固定日期、身份新增一次、故障／取消由回歸覆蓋 |
| 6 既有路徑 | 本輪 Debug arm64 建置與 W3／W4／W5／W6／W7 runner 通過；沿用 W0–W6 的配置、遷移、播放器／彈幕證據，不擴大成所有播放器、完整彈幕或最低系統重驗 |

| 完成下載 | 傳輸 bytes | 完整分段 | 完成檔 libmpv 時長／尾段（秒） |
| --- | --- | --- | --- |
| 既有 Archive MP4 基線 | 43,315,070 | 不適用 | 596.4167／595.25 |
| 稀飯原第二線第 2 集 HLS→MKV | 486,921,692 | 306／306 | 1560.148／1558.974 |

下載任務始終保留原 source／episode／line／quality／account 及目錄策略；HLS 恢復按 W6 明示重新下載全部分段，不拼接舊片段。Didahd owned 代理已實際註冊、匹配端口／路徑／有效期、拒絕未註冊 loopback 且不帶 Cookie；原 3071-7-1 任務 379／552 段後明示 `failed/mediaUnavailable`，未更換來源或宣稱完成。另一公開目錄樣本本輪回 `notFountData`，亦未冒充成功。

17 站實際搜尋均有觀察記錄：Didahd、Dilidili、Fqdm、海星、Jibi、Rebo、Senfun、Wedm、Xifan、櫻花取得結果；Fqdm／Jibi 次頁各 9 個新身份、海星 24 個、Wedm／櫻花各 10 個。E-ACG／Forest／Kanba／Youknow 回 403；風車驗證頁與 Hanime 響應結構回失敗；Girigiri 靜態請求回空、訪客瀏覽器另被導向 502 主機，本輪未確認可用搜尋，不當成健康站點。單站限制不抹掉其他來源資料，也不聲稱全部 17 站或所有線路可播／可完整下載。

實際播放使用安裝版 IINA 的 libmpv 軟體 render API／臨時原生 NSWindow，取得影格與尾段播放，再 destroy；這是媒體視窗解碼證據，不是官方 IINA／mpv CLI 的完整版本相容驗收。當次建置 App 另啟動隔離 Core Data／快取 profile，原生主視窗截圖保留；沒有新增 W8／W9 或永久 debug 頁。去敏日誌、身份／播放器 JSON、影格及完成媒體在 `.build/w7/evidence/`；臨時程式、驗證 App／profile、原始帶簽名日誌結案清除。macOS 13.5、正式簽署／打包、W2 有效雙帳號與原 M2 帳號下載仍未簽收。

<a id="a-w76"></a>
### A.7.1 W7.6 入口收口證據（2026-10-10，單元／編譯層級）

- 原始碼核對：主視窗、書籤、動態、選集、HTTP、開啟檔案、JSPlayer 及播放器／彈幕接點如 §5.2.5。A.7 的 Processes.shared.browseSearch 是歷史 owner；新呼叫端使用 AppServices.makeBrowseSearch()，不恢復共享搜尋狀態。
- 修補：OpenFilesViewController 將可等待的 openFiles 操作保留在既有 action 內；播放器開啟改為傳遞錯誤，只有成功返回才通知 loadDanmaku／關窗。解析或彈幕準備失敗透過 presentError 回報，空串流回報 notFountData，CancellationError 不顯示錯誤；不再記錄可能帶遠端 URL 的原始錯誤至日誌。
- 修正前：僅抽出可等待操作、尚未修正錯誤處理時，OpenFilesEntryRegression 實際失敗於「opening failure must reach the caller instead of silently returning」，見 .build/w7.6-before-unit.log。修正後同一案例及全部 runner 通過。

| 行為 | 本輪實際驗證 | 未外推範圍 |
| --- | --- | --- |
| 成功與精確選擇 | PlaybackSelection／SourceSearch、播放編碼、BangumiWorkSync／收藏單元通過；離線煙霧由真實 VideoInspectionSession 返回原本機 URL／guest | 沒有開啟媒體；遠端成功與歷史實播仍以 A.7 為準 |
| 取消與隔離 | BrowseSearch 的過時查詢／底層 worker 取消、Discovery 取消不提交、下載取消釋放 lease；新增入口取消不報錯、不繼續準備 | 未重跑真實播放器、HTTP 斷線或多視窗生命週期 |
| 局部失敗 | 搜尋保留成功結果、Discovery 來源故障、元資料離線；新增開啟檔案解析／彈幕失敗與空媒體均保留輸入、回報原錯誤、不進入關窗完成路徑 | 未注入真實播放器啟動失敗；視窗提示外觀與彈幕通知成功路徑待整體驗收 |
| 重開與持久保護 | FavoriteLibrary／WorkLibrary 重讀與舊 schema 遷移；DownloadServiceState 恢復原選擇／帳號／路徑、活動態轉待恢復；偏好、lease、快取檔案保護通過 | 本輪是隔離資料的服務重建／持久重讀，不是 App 重啟；獨立程序歷史證據見 A.7 |

- 執行：bash Tests/run-w7-usecases.sh（九組入口／服務單元加快取檔案系統回歸）、bash Tests/run-dependency-regression.sh --unit（四組）、bash Tests/run-work-library.sh 全部通過。日誌分別為 .build/w7.6-unit.log、.build/w7.6-dependency.log、.build/w7.6-work-library.log。
- 編譯：Debug arm64、未簽署 xcodebuild 通過，見 .build/w7.6-build.log；既有 JSPlayer @preconcurrency 與 AppIntents metadata 警告仍在，不宣稱零警告或最低 macOS 已驗證。
- 離線煙霧：直接執行本次 dylib 的真實 getVideo／openFiles，以 invalid 輸入取得 invalidVideoUrl 並保留輸入，未載入視窗；另一 VideoInspectionSession 在前一 session stop 後返回精確本機 selection／guest。只攔截錯誤呈現、不啟動 App／播放器／listener／真實站點。去敏輸出 .build/w7.6-smoke.log；臨時原碼、二進位與隔離 home 已清除。
- 結論：W7.6 入口與交接實作完成；W2 雙帳號／重新授權、M2-3 有效網站帳號下載及 M2-4 使用中移除仍未簽收。原指定來源清單無可用帳號提供者，未擴充 Bilibili／Douyu 下載。W8／W9、Torrent 產品入口及整體／視窗驗收未開始。


<a id="a-w111"></a>
### A.8 W11.1 驗收證據（2026-10-09）

- 建置入口：`Native/build.sh`／`Native/CMakeLists.txt`，C++17、靜態 `iina_torrent`＋`torrent-rasterbar`；`deps.lock` 固定 2.1.2 commit、try_signal 子模組、Boost 1.89.0、私有 CMake 3.31.8 與下載 SHA-256。Xcode 自動按架構建置並複製三份上游授權。
- 所有權：`TorrentSession` actor 串行持有 C ABI owner；native mutex 保護 session／handles，只有一個 poll consumer，alert 複製為值後才交给 Swift，複用暫存並先排空現有批次。已校驗 bytes 使用 piece-granularity file progress；取消移除 handle／排隊事件但不刪資料，`close()` 等待 session_proxy／disk workers，重複關閉安全。
- 執行：`bash Tests/run-w11-torrent.sh` 載入本專案 Debug App 的 `IINA+.debug.dylib`，經實際 Swift actor／C ABI 驅動兩個 2.1.2 sessions，不重新編譯替代 Swift 實作、不使用 Python binding。三輪各傳输自建 v1 torrent 的 **4,194,427 bytes**，逐 byte 比較與 SHA-256 `3b1695b0bcd6e302bfbe97df367e770aa29e4005f98f99b77892a2b010b9508b` 一致，觀察 peer／finished alerts。完成後取消保留原 bytes、取消再加入、已關閉拒絕命令、十輪 idle 啟停／重複 close 均通過；暫存及 peers 隨 runner 結束清理。
- 工程／相容：App Debug arm64 建置通過；原生 arm64、x86_64 均建置，Mach-O objects／App 的 `LC_BUILD_VERSION` 為 macOS 13.5。原生 fixture 的 dylib 僅系統 CoreFoundation、SystemConfiguration、libc++、libSystem；App 沒有新增 Homebrew／OpenSSL／Torrent dylib，既有 Sparkle／Swift runtime 不變。`bash Tests/run-w6-downloads.sh` 的真實 HTTP／HLS／恢復回歸通過。
- W11.1 當時邊界：僅 loopback TCP，禁用 discovery／tracker／web-seed；TLS、magnet、選檔、DownloadService 與 resume 尚未接入。W11.2 已交付這些任務能力與公開傳輸／TLS 政策，見下；Range／外部播放器、UI、Intel 實機、最低 macOS 13.5 執行及簽署／公證仍不在 W11.1 證據內。原 M2 門檻不變。

<a id="a-w112"></a>
### A.9 W11.2／MT1 驗收證據（2026-10-09）

- 身份與入口：`SourceRegistry` 保留 native `torrent` 來源，分開未選檔的 magnet／本機匯入與 `iina-torrent://file` 精確身份；`TorrentSelection` 保存算法標記 hash 集合、metadata file index、路徑與大小。收藏只接受已選檔身份，不保存原始 magnet／tracker 參數；收藏及 Work／Episode 關聯實際重開後仍為原檔案，舊非 Torrent 選擇保持可解碼。
- 任務所有權：`DownloadService` 沿用 W6 任務儲存、進度與命令；`TorrentTransferPool` 合併檔案優先級、獨立取消與最小有效上傳上限，重複匯入重用活躍或持久 metadata，避免同一 swarm 的多個 metadata session。目錄偏好改動不遷移既有共享資料；完成檔獨立發布，刪記錄／刪檔不破壞其他完成檔或 private pieces；最後使用者及退出均等待 native writer 關閉。
- 恢復策略：metadata 保存身份／佈局，v2 sparse Merkle tree 留在 resume 附件，不冒充完整 piece layer。即使 resume 可解碼也不信任其完成 bits；啟動時由實際檔案重校驗並重建 bitmap，代價是重開時的磁碟校驗工作。有效、缺失及損壞 resume 下，先修改選定檔案的真實 bytes，再經 v2-only／hybrid 任務修復，最終 SHA-256 均與原影片一致。
- 真實執行：`W112_DISK_FULL_DIR=<專用近滿 HFS+ 映像> bash Tests/run-w11-downloads.sh` 完整通過。runner 載入 Debug App dylib 與 2.1.2 原生核心，以 FFmpeg 自建 35 秒 FFV1 多檔素材；v1／v2-only／hybrid 明確選非首影片，完成檔走 `fileForOpening`／ffprobe 並比對 SHA-256。獨立程序的部分進度正常退出、真實 SIGKILL 後重開、共享暫停／取消與 metadata 選擇取消、目錄偏好變更、symlink 外部 sentinel、刪除隔離、四秒無 peer 等待及磁碟映像上的真實 ENOSPC 均通過。
- 網路與安全：P2P 確認及正數上傳上限為匯入／任務前置；native 實測零速率拒絕、有效 loopback 限速、原始 traversal／絕對路徑／symlink metadata 拒絕及 pause／remove writer barrier。所有 peer 地址類別使用限速 global class，無 LAN 豁免。100 MiB 輸入與 FIFO 在讀入前拒絕。公開 session 啟用 discovery 與憑證驗證；private hybrid 使用本機 `.torrent` 驗證，不繞過上游禁止 private metadata exchange 的限制，禁用 DHT／LSD／PEX。受控 HTTPS tracker 的可信 CA 成功、未信任憑證拒絕；未使用網站 Cookie 或未授權內容。
- 建置／回歸：App Debug arm64、native arm64／x86_64 建置通過；OpenSSL 3.5.8 與 CA 鎖定校驗、靜態連結及授權隨包保存，x86_64 fixture minos 13.5、dylib 僅系統依賴。`run-w11-torrent.sh` 三輪精確 bytes／關閉、`run-w3-sources.sh`、`run-w5-favorites.sh`、`run-w6-downloads.sh` 全部通過。W5 含原始 magnet 收藏拒絕的失敗前／修正後回歸；遷移的預期故障注入仍通過。
- W11.2 當時邊界：這是服務／原生核心驗收，不是 Torrent UI 或邊下邊播；後續 W11.3／MT2 證據見下。W11.4／MT3、Intel 實機、macOS 13.5 執行、正式簽署／公證仍未驗證，W2／原 M2 帳號門檻不變。

<a id="a-w113"></a>
### A.10 W11.3／MT2 驗收證據（2026-10-09）

- 原生讀取：薄 C ABI 的 reader／request token、共享 piece deadline 與集中 `read_piece_alert` 分派；註冊等待後才設 deadline，已完成塊沿用同一路徑。取消先於 native 進入、晚到回呼、同塊多 reader 及退出中的 detached read 由 request 身分／owner read lease 保護。每次最多 256 KiB、按 piece／file 邊界短讀；每 reader 同時一個讀取，每 session 最多 32 readers，串流 piece 上限 16 MiB，原生完整 piece 暫存最壞上界 512 MiB。
- HTTP／授權：沿用 NIO loopback server；256-bit token 綁定已登記選檔，六小時到期，最多 32 grants／32 requests，授權及各 request 分別持有 lease。HEAD 忽略 Range；GET 的完整／閉區間／開放尾端／suffix 精確 bytes、Content-Length／Content-Range、206／416 及無授權 404 通過；多重 Range 忽略後回完整 200。逐塊 await 背壓，缺塊不回零值或假 EOF；斷線及撤銷關閉對應等待，URL 不持久化或記錄。
- 共享生命週期：App-linked 實際 HTTP 場景讓兩 reader 等同一缺塊，斷開其中一個後另一個仍收到精確 bytes；撤銷一個播放授權不停止另一個授權或獨立下載，取消下載後播放 reader 仍可讀完整檔。停止 IINA／mpv 的播放會經私有 Unix IPC 的 end-file 事件撤銷 URL；隨後 HEAD 回 404。App 退出先停止播放／撤銷授權，再等待 DownloadService／native writers 結束。
- 外部播放器：使用自建 **600 秒、99,533,414 bytes** 的 FFV1 hybrid 多檔 torrent，明確選 metadata index **2**，seed 上傳限制 **512 KiB/s**。IINA **1.5.0** 與 mpv **0.41.0** 都由 `Processes.openTorrentPlayback` 實際開窗載入；seek 前讀取 owned sparse 檔案確認中段 **300 秒／49,590,538 offset**、尾段 **570 秒／94,497,409 offset** 尚為缺塊，seek 後 IPC time-pos 分別越過 301／571 秒並繼續前進至少 0.5 秒。不是等完整下載後播放，也不是 URL scheme 啟動成功代驗。播放畫面與安全日誌保留於 `.build/w11.3/evidence`，臨時 fixture／runner／下載資料清理。
- 建置／回歸：App Debug arm64、native arm64／x86_64 通過；x86_64 fixture 仍為 macOS 13.5、僅系統 dylib。`run-w11-torrent.sh` 三輪各 4,194,427 精確 bytes／SHA-256，追加 connected-seed reader 取消、已完成塊 offset 與精確 EOF；`run-w11-http-range.sh` 的 17 個溢位／suffix／空檔／錯誤格式／多 Range 邊界通過。`run-w6-downloads.sh` 真實 HTTP／HLS／程序恢復、`W112_PHASE=sharing-v2 run-w11-downloads.sh` 共享暫停／取消回歸通過。播放器驗證主機安裝測試用 Homebrew mpv／FFmpeg；沒有將 Homebrew 原生依賴加入 App。
- 邊界：交付服務與既有播放器接點，沒有新增 Torrent UI。W11.4／MT3、W8–W10、Intel 實機、macOS 13.5 執行與正式簽署／公證仍待驗收；JSPlayer Torrent 能力保持關閉，W2／原 M2 帳號門檻不變。

<a id="research"></a>
## 附錄 B. 技術研究與選型依據

研究依據與產品交付分開：下列來源、選型煙霧及取捨不代表本專案 Skin、脚本或 UI 已實作。

<a id="research-osu"></a>
### B.1 osu-framework／osu 固定版本研究

研究固定版本：`ppy/osu-framework@cdd182d326f62f659cbbf6a68b3b67202132043b`、補充 `ppy/osu@adfbb1ca25f7836f0f3577faac334469e6e9e8ae`，兩者提交日期均為 2026-10-09。已透過 GitHub tree 定位並閱讀下列原始碼；Context7 文件用於入口定位，不以搜尋摘要或其測試 fixture 當作生產行為證據。未建置／執行 osu，結論限於所讀路徑，不宣稱完整倉庫安全審計。

**邊界：** osu-framework 提供 C# 圖形應用的容器、資源、紋理與狀態機制；Skin 查找、`.osk` 匯入／匯出及 Skin 編輯器在 osu 遊戲層。本專案借鑑素材覆蓋、組件契約及可分享文件，不直接依賴此框架、不移植遊戲渲染迴圈／Realm、不相容 `.osk` 或 `skin.ini`。受限 JavaScript 佈局生成是本專案設計，並非此研究證明 osu 提供了脚本沙箱。

| 已讀來源／可觀察機制 | 本專案採用 | 不照搬的部分 |
| --- | --- | --- |
| [ResourceStore.cs](https://github.com/ppy/osu-framework/blob/cdd182d326f62f659cbbf6a68b3b67202132043b/osu.Framework/IO/Stores/ResourceStore.cs)：依 store 順序找第一個非空資源 | 明確、有固定優先級的素材覆蓋 | 缺省可繼承不代表损壞包也可靜默成功 |
| [TextureStore.cs](https://github.com/ppy/osu-framework/blob/cdd182d326f62f659cbbf6a68b3b67202132043b/osu.Framework/Graphics/Textures/TextureStore.cs)：按 key 快取並合併進行中的查找 | 素材共用、同 key 合併載入、切版本失效 | 不搬 GPU atlas 或遊戲執行緒模型到原生 UI |
| [FillFlowContainer.cs](https://github.com/ppy/osu-framework/blob/cdd182d326f62f659cbbf6a68b3b67202132043b/osu.Framework/Graphics/Containers/FillFlowContainer.cs)／[GridContainer.cs](https://github.com/ppy/osu-framework/blob/cdd182d326f62f659cbbf6a68b3b67202132043b/osu.Framework/Graphics/Containers/GridContainer.cs)：容器描述流式排列、網格與尺寸 | 組件樹與容器分離，尺寸變更只重新佈局 | 不把每個按鈕都暴露成可編排功能模塊 |
| [ISkin.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/ISkin.cs)／[ISkinSource.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/ISkinSource.cs)：分開查組件、材質、設定；FindProvider 可將相關資源固定於同一來源 | 語義資源槽、相關狀態素材成組解析 | 不假定 GetConfig 回傳的 Bindable 會即時更新；上游註解明確否定 |
| [SkinManager.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/SkinManager.cs)／[SkinnableDrawable.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/SkinnableDrawable.cs)：集中選擇、SourceChanged 通知後重取組件 | 套用一份完整外觀快照，通知呈現層更新 | 不因換皮重建業務 owner 或重啟下載 |
| [SkinImporter.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/SkinImporter.cs)／[LegacySkinExporter.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Database/LegacySkinExporter.cs)／[LegacyArchiveExporter.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Database/LegacyArchiveExporter.cs)：.osk 入口與 ZIP 封裝 | 自有副檔名、可讀目錄、匯入／匯出閉環 | 不照搬匯入後刪原包政策、损壞 metadata fallback 或缺檔仍匯出的行為 |
| [Skin.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/Skin.cs)／[SkinLayoutInfo.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/SkinLayoutInfo.cs)／[SerialisedDrawableInfo.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Skinning/SerialisedDrawableInfo.cs)：版本化 JSON、位置／尺寸／子節點；原碼包含型別名稱遷移與反射建立實例 | 可序列化佈局、穩定 typeID／instanceID、版本遷移 | 不把 Swift 類名寫入配置、不由外部資料反射建立任意型別；不用空組件掩蓋失敗 |
| [SkinEditorChangeHandler.cs](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/osu.Game/Overlays/SkinEditor/SkinEditorChangeHandler.cs)：序列化快照做撤銷，按型別重用可用組件；註解限定當前 target | 撤銷／重做、按穩定實例身份保存狀態 | 不宣稱上游已解決全工作區多頁撤銷；本專案自行定義交易範圍 |

兩倉庫的 [framework LICENCE](https://github.com/ppy/osu-framework/blob/cdd182d326f62f659cbbf6a68b3b67202132043b/LICENCE)／[osu LICENCE](https://github.com/ppy/osu/blob/adfbb1ca25f7836f0f3577faac334469e6e9e8ae/LICENCE) 為 MIT；本次僅方法研究，沒有複製原碼或素材。未來引用原碼須保留相應聲明；程式碼授權不等於第三方 Skin 圖像、字體或商標可再散布。

<a id="research-torrent"></a>
### B.2 Torrent 前期選型證據

前次選型已檢查 2.1.2 原始碼；實際隔離煙霧使用的是 Python binding **2.1.1**，兩個 loopback session 傳輸自建 1 MiB hybrid torrent，驗證尾塊 deadline 讀取、完整 SHA-256、已完成塊回調及 resume bitmap 序列化。未測 App 橋接、2.1.2 編譯、HTTP Range／IINA 播放或程序重啟恢復；該 wheel 最低 macOS 15.0，不是 13.5 發佈證據。臨時腳本與資料已清理。

參考：[固定版本](https://github.com/arvidn/libtorrent/releases/tag/v2.1.2)、[串流排程](https://www.libtorrent.org/streaming.html)、[2.1.2 native API](https://github.com/arvidn/libtorrent/blob/v2.1.2/include/libtorrent/torrent_handle.hpp)、[Animeko 審查](../research/ANIMEKO_TORRENT_REVIEW.md)。
