# 工作完成記錄

本檔案記錄此專案每次完成工作的交付結果。完成工作後新增一筆，不覆寫既有記錄；按日期排列，同日多筆依完成順序追加。記錄實際改動、驗證與限制，不填入 Cookie、token、授權 header 或完整簽名串流 URL。

## 2026-09-25 — 建立工作完成記錄

- 改動：建立 `docs/history/WORK_LOG.md` 作為後續完成工作的留檔位置；於 `AGENT.md` 訂明記錄方式，並於 `README.md` 標示入口。
- 驗證：確認記錄檔存在，且工作規範與入口指向此檔。
- 限制：本次只調整文檔，未執行 App 建置或執行驗證。

## 2026-09-25 — 接入 girigiri愛動漫點播

- 改動：新增 girigiri 番劇／播放頁分類、選集及線路解析、直連 HLS、外部播放器與書籤接入；內建 JSPlayer 和站方彈幕不宣稱支援。
- 驗證：App Debug 建置完成；隔離編譯並執行實際 Swift 解析器，確認番劇兩條線路、選中第 2 線第 2 集、兩份 HLS 清單回應 200，以及缺集被拒絕；ffprobe 確認媒體包含 H.264 視訊和 AAC 音訊。
- 限制：既有另一個 IINA+ 行程正在執行，未啟動本次產出的 App 或實測 IINA／mpv 視窗；其他站點、該站所有影片與站方彈幕未驗證。

## 2026-09-25 — 保存來源接入待辦

- 改動：在專案根目錄新增 `TODO.md`，記錄 JSON 清單中已完成的首站與其餘 16 項待接入來源。
- 驗證：重新讀取 `TODO.md`，確認逐站順序、完成標記及播放驗證限制已保存。
- 限制：本次未接入或驗證下一個網站。

## 2026-09-25 — 嘀嗒影视點播接入（待視窗驗收）

- 改動：新增 `didahd.pro`／`didahd.xyz` 詳情及播放頁辨識、`4kvm` 分集與本機 HLS PNG→TS 解包，接入選集、書籤分類與外部播放器 URL；其餘加密線路和網盤未宣稱支援。
- 驗證：App Debug 建置成功；啟動本次產出的 App，透過其 loopback API 解析樣本第 1／2 集、拒絕錯誤 host 與不存在集數；本機播放清單及首／中段 TS 回應可讀，ffprobe 辨識 H.264／AAC，ffmpeg 成功解碼前三秒。
- 限制：系統拒絕本 session 的 UI 輔助操作及擷取畫面；未在 IINA／mpv 視窗驗收。使用者要求停止本 session 後續測試，故 `TODO.md` 維持未勾選，重開後續驗。未測其他線路、更多節目、站方彈幕或內建 JSPlayer。

## 2026-09-25 — 完成嘀嗒影视選集與播放驗收

- 改動：修正 `SelectVideoViewController` 的嘀嗒集數標題顯示與選中集數的網址分派；將該站待辦標記為完成，更新 README 狀態。
- 驗證：本專案 App Debug 建置成功；實際 App 視窗顯示 BD1 集數，選取第 2 集後輸入欄顯示對應播放頁網址。使用者另行確認能正常播放；依使用者要求，構建後未再由助理完成播放器視窗實測。
- 限制：使用者未說明播放器類型或所測集數，故不推定特定播放器／集數均通過；其他加密線路、網盤、內建 JSPlayer 與站方彈幕未驗證或接入。

## 2026-09-25 — 接入叽哔动漫點播

- 改動：新增 `jibi.cc` 詳情及播放頁辨識、站點解析器、選集與線路、書籤分類及直連媒體外部播放器路徑；加上站點本地化和 Xcode Sources 引用。僅接受未加密、免付費的 HTTPS HLS／MP4，未接入內建 JSPlayer 與站方彈幕。
- 驗證：以實際 Swift 原始碼隔離編譯執行，核對兩個公開番劇頁、選取第 2 線第 2 集、線路名稱與集數對應、書籤 NSPredicate、錯誤 host／路徑及不存在集數；兩條樣本 HLS 經 FFmpeg 各解碼一秒；工程 pbxproj 與 xcstrings 格式檢查通過。
- 限制：依 `TODO.md` 清單約定，全部站點完成後再統一構建完整 App 測試；此項未執行 App 建置、實際 UI 選集、IINA／mpv 視窗播放、其他作品與線路或站方彈幕驗收。

## 2026-09-25 — 接入 E-ACG 點播

- 改動：新增 `eacg1.com` 詳情及播放頁辨識、線路／分集與公開未受限媒體解析；接入外部播放器直連、選集、書籤分類、本地化及 Xcode Sources。內建 JSPlayer 與站方彈幕不宣稱支援。
- 驗證：以實際 Swift 解析器隔離編譯並連線執行，核對兩條線路各 13 集、選中第 2 線第 2 集、兩份 HTTPS HLS 解析與錯誤 host／路徑／不存在集數拒絕；兩份 HLS 各由 FFmpeg 解碼一秒；工程 pbxproj 與 xcstrings 格式檢查通過。
- 限制：依 `TODO.md` 清單約定，全部站點完成後再統一構建完整 App 測試；未執行 App 建置、實際 UI 選集、IINA／mpv 視窗播放、其他作品與線路、受限線路或站方彈幕驗收。

## 2026-09-25 — 接入森之屋动漫點播

- 改動：新增 `senfun.in` 詳情／播放頁辨識（含 `ep1_02`、`ep1a` 等非純數字集數 slug）、選集、逐集線路（`/_senfun_plays/{id}/{slug}` JSON 的 `video_plays`）直連 HTTPS HLS 解析；接入外部播放器直連、書籤分類、本地化及 Xcode Sources。僅接受 HTTPS m3u8／mp4 線路；內建 JSPlayer 與站方彈幕不宣稱支援。
- 驗證：以實際 Swift 原始碼隔離編譯連線執行 41 項檢查全數通過，涵蓋網址辨識（詳情／播放／後綴 slug／http／query／拒絕錯誤 host 與路徑）、書籤 NSPredicate、liveInfo 在線／缺集離線、467 集目錄選集定位、decodeUrl 線路鍵名／順序／直連 URL、詳情頁自動選首集、錯誤 host 與不存在集數的錯誤路徑；ep1 的 LZZY 兩條線路由 FFmpeg 各解碼一幀；工程 pbxproj 與 xcstrings 格式檢查通過；臨時 harness 已清除。
- 限制：依 `TODO.md` 清單約定，全部站點完成後再統一構建完整 App 測試；未執行 App 建置、實際 UI 選集、IINA／mpv 視窗播放或站方彈幕驗收。同集 YHZY 線路播放清單的分段使用偽裝副檔名，FFmpeg HLS demuxer 依副檔名拒絕；另一集 wjzy2 線路媒體主機自本機無回應；兩者保留於選單但未驗證可播，其他作品與線路亦未逐一驗證。

## 2026-09-25 — 接入去看吧點播

- 改動：新增 `11kt.net`（同站 `www.11kt.net`／`qkan8.com`／`www.qkan8.com` 一併辨識）詳情／播放頁辨識、`Kanba.swift` 站點解析器（選集、逐線路目錄、播放頁 `data-play` 編碼：4 字元鹽＋去首位 base64，解出直連 HTTPS HLS／MP4）、外部播放器直連、書籤分類、本地化及 Xcode Sources；僅接受未加密、免付費的 HTTPS m3u8／mp4 線路，內建 JSPlayer 與站方彈幕不宣稱支援。另依使用者指示暫緩风车影视（`dongmandaquan.vip`），於 `TODO.md` 標註。
- 驗證：以實際 Swift 原始碼隔離編譯連線執行 62 項檢查全數通過，涵蓋網址辨識（詳情／播放／大小寫 host／query／fragment，及拒絕錯誤 host、錯誤路徑、port、使用者資訊、缺 `.html`、`nid 0`）、書籤 NSPredicate（4 host × 2 scheme，拒絕他站與同站非播放路徑）、liveInfo 在線／缺集離線、三線路 26＋26＋26 集目錄與選集定位、電影單集目錄、decodeUrl 線路鍵名／qualityIndex／直連 URL、詳情頁自動選首集、錯誤 host 與不存在集數的錯誤路徑；樣本集第 2 集三線路（兩條 AES-128 HLS、一條 MP4）及電影樣本 HLS 由 FFmpeg 各解碼一秒，ffprobe 確認 H.264／AAC；工程 pbxproj（plutil）與 xcstrings（JSON）格式檢查通過；臨時 harness 與含媒體位址的輸出檔已清除。
- 限制：依 `TODO.md` 清單約定，全部站點完成後再統一構建完整 App 測試；未執行 App 建置、實際 UI 選集、IINA／mpv 視窗播放、內建 JSPlayer 或站方彈幕驗收。跨線路備援依集數編號（nid）對應同集，若各線路集數編號不同步可能對應到不同集；其他作品與線路未逐一驗證。

## 2026-09-25 — 接入海星动漫點播

- 改動：新增 `www.haixingdmx.com`（同站裸域 `haixingdmx.com` 一併辨識）詳情／播放頁辨識、`Haixing.swift` 站點解析器（選集、逐線路播放Ⅰ–Ⅵ目錄、`/playinfo` cookie 挑戰取址：`t1`／`k1` 回以 `k2`／`t2`／`m2t`／`im`／`kr`，十六進位回應按 UTF-8 解碼出直連 HTTPS HLS／MP4／FLV／MKV）、外部播放器直連、書籤分類、本地化及 Xcode Sources；解析器以停用 cookie 儲存的專屬 URLSession 送出挑戰，避免共用 cookie 罐回送過期 `t1` 使挑戰失效。內建 JSPlayer 與站方彈幕不宣稱支援。
- 驗證：以實際 Swift 原始碼隔離編譯連線執行 78 項檢查全數通過，涵蓋網址辨識（詳情／播放／裸域／大小寫 host／query／fragment，及拒絕錯誤 host、錯誤路徑、port、使用者資訊、缺 `.html`、畸形 play slug）、書籤 NSPredicate（2 host × 2 scheme × 2 路徑，拒絕他站與同站非播放路徑）、liveInfo 在線／缺集與無資源作品離線、樣本集 5 線路各 25 集目錄與選集定位、電影 2 線路單集目錄、decodeUrl 線路鍵名／qualityIndex／直連 URL／詳情頁自動選首集／錯誤路徑；樣本集五線路與電影兩線路解析所得 12 份去重串流（六個媒體主機）全數由 FFmpeg 各解碼一秒，ffprobe 確認 H.264／AAC；工程 pbxproj（plutil）與 xcstrings（JSON）格式檢查通過；臨時 harness 已清除。
- 限制：依 `TODO.md` 清單約定，全部站點完成後再統一構建完整 App 測試；未執行 App 建置、實際 UI 選集、IINA／mpv 視窗播放、內建 JSPlayer 或站方彈幕驗收。站方網頁播放器對含非 ASCII 路徑的媒體 URL 會重複百分比編碼致 404，本接入按 UTF-8 還原後可播，行為與站方播放器不同；跨線路備援依集數標題（如「第2集」）對應同集，標題不同時退回集序對應；其他作品與線路未逐一驗證。

## 2026-09-25 — 接入樱花动漫點播

- 改動：接入 `www.yinghua2.com`（現跳轉 `www.yinghuaaa.com`；兩網域 www／裸域）詳情／播放頁、六條線路與分集、未加密 HTTPS HLS／MP4 直連、書籤、本地化及 Xcode Sources；依集數標題對應跨線路相同集，避免線路含第00集時 nid 錯位。內建 JSPlayer 與站方彈幕不宣稱支援。
- 驗證：以實際 Swift 來源隔離編譯連線執行 41 項檢查通過，涵蓋網址與書籤辨識、錯誤網域／路徑、封面標題、缺集離線、六條線路與選中第 2 集定位、逐線路取址及第00集錯位的跨線路資源對應。FFmpeg 對樣本第 2 集六條線路解碼一秒：四條成功，兩條媒體主機 TLS EOF；工程 pbxproj 與 xcstrings 格式檢查通過。
- 限制：依 `TODO.md` 待全部站點完成後統一建置完整 App；尚未驗證 IINA／mpv 視窗、內建 JSPlayer、站方彈幕或所有作品與線路。成功解碼的一條線路曾於退出時回報讀取逾時；失敗的兩線仍保留在網站提供的選項中，未宣稱它們目前可播。

## 2026-09-30 — 依影音來源待辦逐站接入與統一建置

- 改動：核對既有嘀哩嘀哩接入；新增 Youknow、Fqdm、Hanime1、Wedm、Forest 解析器及網址／書籤／選集／外部播放器分派、本地化與 Xcode Sources；修正原有樱花選集 `flatMap` 編譯錯誤，排除新站點誤啟彈幕。风车影视保持先前暫緩，热播之家保持未接入。
- 驗證：公開站點頁面與播放器資料已檢查；嘀哩嘀哩一條 HLS、新优酷與番茄動漫各兩條 HLS、Hanime1 1080p／720p MP4、wedm 與影视森林各兩條 HLS，FFmpeg 各解碼一秒。Xcode Debug 無簽署完整 App 建置成功；先前編譯失敗原因為既存 `.children` 語法，修正後重建通過。工程 plist 與 xcstrings 格式檢查通過。
- 限制：依待辦要求僅構建，尚未在本次 App 中測試選集 UI、IINA／mpv 視窗、JSPlayer、站方彈幕、所有作品或線路；媒體解碼與 Swift 解析器的完整運行並非同一驗證。热播之家現跳轉 `rebozj.cc`，樣本播放頁使用 `encrypt=3` 密文，站方 Artplayer 在自動化環境跳往百度，無可驗證外部媒體 URL，不宣稱播放接入；风车影视仍依使用者指示暫緩。

## 2026-09-30 — 補接先前暫緩的风车影视

- 改動：新增 `dongmandaquan.vip`（www／裸域）詳情與播放頁網址辨識、`Fengche.swift` 解析器（播放列表、選集、逐線路 `player_aaaa` 公開 HTTPS HLS／MP4）、書籤、外部播放器直連、本地化及 Xcode Sources；排除未驗證的 JSPlayer 與站方彈幕路徑，騰訊外部影片網址不冒充可播串流。
- 驗證：實際 Swift 來源隔離編譯連線執行，涵蓋正反網址、書籤 NSPredicate、詳情標題／封面、缺集離線、8 線路目錄及所選第 2 集、7 條直連串流、騰訊外部線路拒絕；樣本兩條 HLS 經 FFmpeg 各解碼一秒。Xcode Debug 無簽署完整 App 建置、工程 plist 及 xcstrings JSON 格式檢查通過。
- 限制：依待辦僅建置，未在本次 App 實測選集 UI、IINA／mpv 視窗或內建 JSPlayer；未驗證其餘作品和全部線路的媒體解碼。热播之家仍因無可驗證外部媒體 URL 而未接入。

## 2026-10-07 — 制定前端全面重構工作文檔

- 改動：新增 `docs/plans/FRONTEND_REFACTOR_PLAN.md`，確立「放映手帳」UI、語義主題及後續編輯器邊界；涵蓋搜尋、Bangumi 基礎資料、每日更新推薦、配置／原生統一來源、真實下載、雙欄收藏、號池與快取。定義資料契約、狀態擁有者、W0–W8 工作包、依賴、端到端驗收與避免過度防禦性編程規則。同步 README 入口與 PROJECT 下一階段範圍。
- 驗證：核對現有前端目錄、來源協議與解析分派、Core Data 目錄及歷史驗證記錄；以腳本檢查三份規劃／入口文檔，13 個本地 Markdown 連結有效，程式碼區塊成對。
- 限制：僅變更文檔，未修改 App 程式或工程；未建置、啟動 App 或驗證規劃中的新功能。工作包均待實作，主題可視化編輯器及觀看進度雙向同步不在本階段交付範圍。

## 2026-10-07 — 調整為基礎功能優先、UI 後整合

- 改動：重排 `docs/plans/FRONTEND_REFACTOR_PLAN.md` 為契約與基礎模塊、功能串接、UI 整合；將頁面互動從基礎服務驗收拆出。工作包改為 W0–W10，W7 功能閉環驗收通過後才開始 W8 主題／新殼及 W9 頁面，W10 全面切換。保留原有功能與視覺方向，不以新 UI 作為基礎功能前置條件；同步 README 與 PROJECT。
- 驗證：腳本檢查三份文檔的 13 個本地連結、程式碼區塊配對與章節引用；11 個工作包無重複、依賴全部有效且無環，確認 UI 僅在 W7 後開始。
- 限制：只調整工作文檔，未實作基礎模塊或 UI，未建置或啟動 App。

## 2026-10-07 — 完成 W0 基線與資料盤點

- 交付：新增 `docs/plans/FRONTEND_W0_BASELINE.md`，涵蓋 SupportSites 全部 27 case 的來源／播放器能力矩陣、選單／鍵盤／URL／HTTP／WebSocket／書籤／設定／登入入口及 W1–W10 服務遷移位置。記錄歷史失效、未驗證、W0 既存缺口及回歸判定；同步 FRONTEND_REFACTOR_PLAN、README、PROJECT 的 W0 已驗收狀態，W1–W10 未開始。未修改 App、工程或 Core Data 模型。
- 資料：備份 551 檔，真實資料為 1 筆書籤及 15 個偏好鍵；SQLite backup／integrity_check、全部資料表值與身份相等、偏好 plist 相等、實際 Core Data 還原重讀通過。原 profile 551 檔 SHA-256 全未變。700 權限私人永久備份置於工程外 `~/Library/Application Support/IINA-ANI-W0-Backups/2026-10-07.6cyfunae/`；含私人資料及憑證，禁止提交或分享。另以三類公開書籤驗證隔離 App 重啟重讀與排序。
- 建置／運行：README 的 Debug 無簽署 xcodebuild 成功；複製此產物、僅更改測試副本 Bundle ID 及重簽，以 CFFIXED_USER_HOME 隔離資料。實際操作舊主視窗、搜尋結果、選集、File Open 及四個設定 pane，保存 `.build/w0/evidence/` PNG。loopback 實測 Fengche 第2集、girigiri、B 站影片／直播解析 HTTP 200；無支援／缺參數／未知 route HTTP 400；placeholder／測試頁 200；WebSocket 升級 101 並關閉。Fengche 备用③ H.264／AAC 一秒解碼成功，线路② probe／decode 失敗並保留失敗記錄。200 檔來源 SHA-256 manifest 已保存。
- 既存缺口：六站選集 UI 缺少 display／selection 分派；Fengche 真實 UI 呈現空葉標題，選中後回寫空 URL。另記錄 IINA plugin 已快取時 open(result:) 的靜態無播放呼叫風險、主 UI 解析依賴外掛門檻及 HTTP 不走共用取消任務；W0 僅建立基線，不擅自修成 W1／W3。
- 限制／結束：未實測 IINA／mpv 視窗載入、JSPlayer 直播、登入、多帳號、完整彈幕生命週期、代理本次拉流、全部站點／線路、macOS 13.5 或發佈；不把 API／FFmpeg 成功稱為播放器驗收。臨時腳本、原始 AX／完整媒體回應等驗證 scaffolds 結案清除；資料備份與去敏證據保留。測試 App 正常退出 exit 0、19080 釋放；使用者原有 IINA 未被停止。W0 已驗收，依要求結束本次 session，不開始 W1。

## 2026-10-07 — 修復 W0 留檔的既存功能缺口

- 選集：SelectVideoViewController 補齊 dilidili／youknow／fqdm／wedm／forest／fengche 的葉標題與 item.url；另修復 Fqdm 現行 module-play-list 目錄 selector。六站均以真實原生 UI 選中非首集，回寫各自正確 URL 並取得實際線路／品質列表；Fqdm 修復前缺目錄，修復後 nid/2 回傳五條線路。
- 播放入口：MainViewController 將 IINA 外掛檢查限定於 IINA，mpv 不再誤擋；保留使用者在 W0 後已恢復的 openWithPlayer 呼叫，刪除重複 guard 與過時註解。YouGetJSON 的 forDash 查址在無 dashUrl 時回傳 direct URL，保留音軌；未啟用 MPD 服務。SupportSites 僅允許六個已接入直播來源進 JSPlayer。
- 直播：JSPlayer 啟動 QieTV 既有彈幕；Douyu 從現行 room_ids／zhtId／zhtName 建立主題房間資料，按 pageData1／topicName API 契約取名；內嵌 JSON 與元件掃描處理 JS 跳脫、字串括號及多位元索引。PUBGYLSJS 真實 UI 顯示 30 個具名房間，選第二個 /5818871 取得原畫；一般房間與不含 switch-room 元件的既有回退未移除。
- HTTP：HTTPHandler 重用 bilibiliUrlFormatter；公開 b23 短連結的 /video 與 normal /video/iinaurl 均 200，無支援網址及缺 url 仍 400。沒有把獨立 HTTP 請求接到 UI 共用取消 Task，沒有假重試／媒體回應。
- 媒體失敗定位：Fengche 线路② CDN 為 NOERROR 無 A／AAAA且指向本環境受限 777 埠；Senfun 失敗分段或主機 NXDOMAIN，另有 FFmpeg 副檔名政策；Yinghua 舊 EOF 主機 NXDOMAIN／無 A。解析器取址與站方資料一致，其他樣本線仍可解碼；無來源碼更動，不宣稱遠端故障已修复。另觀察 Yinghua 跳轉至當前未辨識的新域名，未在本次擴增接入。
- 更正基線：DouYin 實際 Copy Resources 相位已提供 Resources/DouYin/douyin.html，最終 Bundle 資源查找通過；W0 的根目錄風險判定不成立。Preferences storyboard 的 initialViewController 在本次開始前已由使用者設定，保留並確認最終建置無原先入口警告；其他既存警告未處理。
- 驗證：最終 Debug arm64 無簽署 xcodebuild 成功；org.iina-ani.gap-repair 測試副本／CFFIXED_USER_HOME／獨立偏好／19180，不接管使用者 IINA／IINA+。真實主介面雙擊經 Processes 啟動臨時真實 libmpv runner，載入媒體至 2.021 秒、1920×804，停止及銷毀成功；不是官方 mpv CLI 或 IINA 視窗驗收。實際 App 模組 smoke 通過直連／音軌／DASH 優先／缺品質、Web 能力、DouYin 查找、Douyu Unicode 與字串括號等樣本。
- 彈幕與釋放：QieTV WKWebView 實際收到公開留言；操作兩個独立視窗，在 windowWillClose 斷點觀察 socket／danmaku／webView 皆 nil，另一窗保留 danmaku，之後關閉與重開。影片 FLV 回 403／decodedFrames=0，不以留言或 Loading 冒充播放；強制斷線重連與 heartbeat Task 狀態未驗證。
- 留檔／清理：修復狀態追加 FRONTEND_W0_BASELINE.md §8，W0 歷史快照保留；同步 README、PROJECT、FRONTEND_REFACTOR_PLAN。去敏 PNG／AX、最終建置、模型／libmpv 結果及診斷保存 .build/gap-repair/evidence/ 與工程外私人 W0 備份的 gap-repair-evidence/。只移除本次臨時 App、home、測試偏好、runner／AX／模型腳本、fixture server 及含簽名 URL 的回應；19180／19181 釋放，原備份 raw／restored 不動。
- 限制：cc163 彈幕、MPD 註冊、既有未支援加密線及新服務未實作；外部播放器視窗、抖音實際彈幕、全部來源／線路、登入／多帳號、macOS 13.5 與正式發佈未驗證。未建立新的永久測試 target；以實際 App／模組 smoke 留證。W1–W10 仍未開始。

## 2026-10-07 — 完成 W1 最小契約與持久化基礎

- 身份／保存：新增 `SourceItemRef`／`PlayableSelection`，source ID 不依賴顯示名稱，頁面／分 P 身份不含短效媒體 URL；`WorkLibrary` 以真實 Core Data 保存 Work／Episode／WorkSourceLink 穩定 UUID 及明確集數映射。同名不合併，正篇／SP／第 0 集分開，拒絕集數換作品、跨作品／重複／來源不一致映射；元資料更新保留來源關聯。
- 模型：新增 `Library v0.4` 三個實體，原 Bookmark 欄位不變，保留全部舊模型；AppDelegate 啟用自動／推斷遷移並按來源模型是否有 order 決定舊排序初始化，v0.3 分數排序不重寫。回退需退出 App 並還原一致的遷移前 store／WAL／SHM 或 SQLite backup，不以降模型版本冒充可逆遷移。未遷移使用者真實 store。
- 解析／切換：VideoDecoder 集中 selection、inspect、resolve 及品質準備，原始站點分派與 B 站 URL formatter 改為私有；主 UI、書籤、B 站動態多分 P、HTTP、JSPlayer、OpenFiles 共用同一服務。VideoTreeNode 統一葉標題與選擇 URL；YouGetJSON 保留選擇、指定品質及主／備援槽位，既有 HTTP CodingKeys／URL scheme 不變。非空 accountID 在 W2 前明示不支援，未實作假帳號上下文。
- 取消／選集：Processes 只持有搜尋 inspection Task／ID，替換／停止取消舊搜尋；Main 的 request ID 阻擋舊結果、錯誤及 spinner 收尾，不取消 HTTP 或獨立播放。真實 UI 發現選中普通集後再次顯示目錄的回歸，修正 SelectVideo 的 directly 判斷；修後同一目錄在 SP 之後選正篇，回寫 sid/4/nid/2 並顯示五個品質。
- 持久化回歸：`Tests/run-work-library.sh` 編譯實際 SourceSelection／WorkLibrary／BookmarkOrderMigration 與 momc 模型，SQLite 保存／關閉／重開、同名不同作品、正篇／SP／第 0 集、映射／元資料更新、非法關聯與全部舊版本 Bookmark store 遷移通過。沒有在 App 內植入驗證 hook，也沒有建立只驗證接線的永久測試。輸出 `.build/w1/evidence/persistence.txt`。
- 建置／服務：最終 Debug arm64、CODE_SIGNING_ALLOWED=NO 的 xcodebuild 成功。載入最終生產模組運行真實 Fqdm 目錄／選集、選擇編碼重讀後重新解析、B 站 festival／分 P 規範、取消／替換、獨立本機播放及無效帳號／品質／備援拒絕；另實例化實際 OpenFiles storyboard／controller，驗證本機檔、品質及無效輸入。HTTP b23、普通影片／Fqdm 集數、normal IINA scheme、有效 URI percent-encoded 品質均 200，缺參數／不支援 400，JSON 頂層欄位未增加。
- 實際視窗：org.iina-ani.w1-smoke 測試 App 副本、CFFIXED_USER_HOME、獨立偏好及 19280，不接管使用者 IINA。原生主介面選集後雙擊品質，經 Processes 的 customMpvPath 啟動真實 Cocoa／libmpv runner；遠端影片已載入、time-pos 2.023、1920×1080，停止／銷毀完成。另渲染相同已解析候選並擷取真實影片畫面；本機 640×360 fixture 亦有實際解碼畫面。這是安裝版 IINA 的 libmpv，不是官方 mpv CLI 或 IINA 視窗版本相容驗收。
- 留檔／清理：去敏建置、服務／控制器／模型輸出、AX 與 PNG 保存 `.build/w1/evidence/`；同步 README、PROJECT、FRONTEND_REFACTOR_PLAN 及 W0 文檔的當前狀態，保留歷史原文。已清除本次隔離 App／home／偏好、AX／runner／臨時腳本／媒體、完整 HTTP 回應及包含使用者目錄列表的 picker／menu AX；保留永久行為測試。測試 App 正常退出，19280 已釋放，使用者原有 IINA 行程仍在。
- 邊界：W1 已驗收；W2–W10 未開始。沒有號池／登入隔離、registry／配置引擎、Bangumi、收藏雙欄、下載或新 UI；全部來源／線路、JSPlayer 直播、完整彈幕生命週期、官方播放器版本、macOS 13.5 及正式發佈未全面回歸。未聲稱既存遠端媒體／加密能力限制已修復。

## 2026-10-07 — W2 偏好、網站號池與快取實作交付

- 偏好：沿用 UserDefaults 與既有播放器／品質／彈幕鍵，加入來源啟停／預設帳號、security-scoped 下載目錄及 1–8 併發策略；新任務讀取不可變 snapshot，不搬動既有檔案。
- 帳號：SiteAccounts actor／Keychain 保存 Bili／Douyu 多帳號及狀態，legacy Cookie copy-before-delete、不覆蓋已選帳號、不假設有效登入。新增、停用、移除、本機登出與重新授權使用同一服務；本機登出不撤銷其他裝置會話。使用 lease 是獨立 UUID token，重複 release 不解除其他任務；重新登入在伺服器驗證返回後再次檢查其他 lease，避免 actor reentrancy 期間覆蓋新任務的身份。
- 切換：現有 Bili／Douyu sheet、LoginWebView 及 legacy Bili controller 每次使用獨立 nonPersistent WebKit store，取消不提交／不改預設；Cookie 名稱不算登入成功，必須通過 Bili nav／Douyu safeAuth。Bili／Douyu HTTP、動態與彈幕初始化改用帳號 Session；WBI 按帳號隔離，解析／品質／點播彈幕使用捕獲的 selection，已保存 nil 是 guest，不輪換、不採用後來的新預設。
- 快取：ImageCacheService 僅清理／淘汰 owned 封面／表情與元資料，分列暫存與完成檔區；上限 512 MiB 可保存，不跟隨 symlink。AppDelegate 在建立 shared SD cache 前設定 owned 目錄，啟動套用上限／淘汰；既有 Advanced 大小／Clear 改用同一服務，未新增設定頁。刪除無 caller 的 ImageLoader 並更新工程 Sources。
- 回歸：最終 Debug arm64 xcodebuild 成功，project.pbxproj plutil 與三個 runner 的 bash syntax 通過。Tests/run-w2-services.sh 連結實際 App 模組，偏好重讀、下載策略、兩組同站 Keychain fixture、遷移／登出／移除、使用中拒絕、lease 冪等性、guest pinning、來源停用及 filesystem 大小／淘汰／清理／symlink 保護通過；run-work-library.sh 的全部舊模型遷移與身份／映射重開仍通過。沒有加入只驗證接線的永久測試。
- 運行：變更前兩個生產 LoginWebView 共用 store；最終生產模組實際掛載的兩個容器 Cookie 不互通，取消停止完成回呼；兩站真實 validator 都拒絕無效 Cookie，兩站登入頁有實際 WK snapshot。原生事件點擊現有 Advanced Clear，封面／元資料清零、暫存與完成檔 fixture 各保留 4096 bytes，介面更新 0.00 MB。生產 decoder 保存 guest 後更換預設仍到達來源，新選擇需授權而非 fallback，停用拒絕新解析；原始來源已刪除的 Bili 影片仍回來源錯誤。最終原始碼 App 的實際本機 AAC 資源 HTTP 200、原五個 JSON 頂層欄位保留；不是播放器播放驗收。
- 證據／清理：去敏輸出／建置及 view／WK PNG 保存 .build/w2/evidence/，登入 QR 已遮蔽；同步 README、PROJECT、FRONTEND_REFACTOR_PLAN 與 W0 當前狀態，歷史原文保留。臨時 host／解碼／redaction 程式、SDK 抓取、隔離 App／profile、原始 HTTP／AX／sample／日誌及合成偏好清除；只保留永久測試與去敏證據。原有 IINA 行程未被接管。
- 驗收邊界：W2 實作交付，不標為完整登入驗收。沒有提供或借用真實帳號；兩個真實帳號的伺服器 UID／Cookie 一致性、有效 Cookie 安全提交及失效後重新授權成功仍需人工平台授權，合成 valid metadata 只證明離線 lease 契約。真實下載中的目錄／清理／持續 lease 保護在 W6／W7；完成檔區大小不是任務或任意 Downloads 統計。完整彈幕／播放器、macOS 13.5、正式發佈及 W3–W10 未全面驗收／未開始。

## 2026-10-07 — 縮減非必要測試與日常構建範圍

- 依使用者要求，在 FRONTEND_REFACTOR_PLAN §8.3 明訂最小有效測試集合：新增測試須有消費者可見失敗或重要邊界依據，刪除／合併接線、文案、偶然預設值與同路徑重複項；不以覆蓋率或測試數量擴張工作。
- 日常只跑受影響 target、契約與直接依賴，批次修改後增量驗證，重用 fixture／runner／构建產物；文檔改動不建置 App。完整回歸留在整合／W7／W10／發佈關卡；必要的資料、身份、檔案安全及真實運行驗收不縮水。
- 驗證：檢查新增規則與既有驗收／結案要求一致及文檔格式／連結；本次政策變更沒有刪除必要回歸或觸發額外 App 構建。

## 2026-10-07 — 鬥魚登入去敏診斷與人工登入記錄

- 診斷：LoginWebView 與 SiteAccounts 僅在 DEBUG 記錄鬥魚登入階段、非空 Cookie 的存在布林、safeAuth HTTP／業務錯誤碼、去敏例外類型及 Keychain 保存邊界；不記錄 Cookie 值、token、UID、暱稱、授權 header、完整請求網址或回應本文。未變更登入成功判定或帳號保存契約。
- 驗證：README 的 Debug arm64 無簽署增量 xcodebuild 成功。隔離 home 的 throwaway harness 連結生產 App 模組，實際 Coordinator／WKWebView／safeAuth 拒絕無效 marker（HTTP 200、error 16），帳號仍 needsLogin、預設仍 guest；輸出不含 marker 值。未新增永久測試。
- 人工登入：啟動本專案產出的 App、打開 Settings → Sites → 鬥魚登入；背景收集器只保存診斷行。使用者完成登入時 dy_auth／acf_auth／UID／暱稱／did 均非空，passportAuth=true；safeAuth 回 HTTP 200、error 3，Coordinator 回 validationFailed 並關閉 sheet，沒有到達 keychain.store。去敏紀錄保存於 .build/douyu-login-capture.log。
- 定位／限制：本次排除已觀察路徑的 Cookie 尚未齊全及 Keychain 寫入失敗，停在 W2 新增的 safeAuth 驗證。公開無登入請求確認缺 client_id 時 error 3／client_id错误，帶 client_id=1 時 error 16／未登入；未記錄人工登入回應的 msg 或實際跳轉，不能斷言是哪個參數／跳轉問題。未將 error 3 當成功，未宣稱已修復真實登入；未清除使用者登入資料。

## 2026-10-07 — 修復鬥魚主站帳號驗證

- 協議：核對現行官方首頁 module 72750，safeAuth 的 client_id 仍為 1，沒有改成猜測值。官方 header.umd._0a75dfe.js 的 UserPaneEpics.getInfo 使用主站 /lapi/member/api/getInfo、client_type=0 及毫秒 d；UserInfoDto 的伺服器 UID 是 msg.uid。這是主站帳號查詢，而非 passport SSO 交換；無憑證及合成無效 acf_auth 均回 HTTP 200／error 1／uid 0。
- 修正：SiteAccounts 的登入提交、狀態刷新及來源操作統一改用此官方主站介面，保留隔離 Session／Cookie jar。只有 HTTP 200、error 0、正值伺服器 UID 與 acf_uid 一致才可提交 Keychain；error 1 表示失效，其他錯誤、身份不一致及格式異常拒絕保存。名稱仍優先解碼暱稱 Cookie，缺少暱稱回傳已驗證的伺服器 UID。Douyu 登入頁與驗證請求共用 Web User-Agent；移除原 safeAuth／JSONP 驗證路徑及其診斷名稱。
- 驗證：Debug arm64 增量 xcodebuild 成功。只運行受影響的 SiteAccountsRegression：真實 Keychain 隔離／遷移／生命週期／lease／guest pinning 保持通過，新增伺服器 UID 不一致、零值／布林／缺失 UID、拒絕／格式錯誤及顯式 guest 的永久邊界回歸。隔離生產 Coordinator／WKWebView 的真實無效 acf_auth 煙霧回 error 1，維持 needsLogin 與 guest，不提交帳號；未記錄 marker 值。
- 人工成功：重啟為修復產物後，使用者回報登入成功；同一次背景記錄顯示 userInfo HTTP 200／error 0、uidMatches=true，依序到達 keychain.store、account.saved、login.succeeded。之後的來源驗證仍回 error 0 且 UID 一致。去敏證據保存 .build/douyu-login-repair.log；App 保持開啟，不重新跑登入或清除使用者憑證。
- 文檔／限制：同步 FRONTEND_REFACTOR_PLAN 的現行帳號驗證契約，歷史 safeAuth 記錄保留。未測試成功登入後重啟重讀、第二個真實帳號或失效後重新授權；不將單帳號成功擴張成 W2 全部人工驗收已通過。背景收集器及臨時 SDK／UI／回歸 harness 結案清除，保留 App、永久回歸與去敏結果。

## 2026-10-08 — 完成 W3 統一來源與有限配置引擎

- 實作：新增 SourceRegistry／SourceConfiguration／ConfiguredSource／SourceCapabilities；全部既有來源由 registry 分類及能力檢查後走共用 VideoDecoder 入口，原生影片／番劇／直播、B23、主題房間及代理保留。Fqdm、Forest 改用 Bundle Sources JSON，刪除原生 actor／enum 分支與工程引用。使用者 sources 可原子重載，版本／必需欄位／重複 ID／host 衝突拒絕並保留最後可用 snapshot；停用不改書籤身份。
- 規則與安全：GET HTML／JSON、路由 capture／query 檔案身份、公開媒體模板及固定 MacCMS 0/1/2 解碼；不引入任意 JS。配置不存 Cookie／token，HTTPS、userinfo／port、redirect／credentialHost 逐目的地檢查，Cookie jar 隔離。公開 CDN 簽名 URL 不誤拒絕；重現並修正跨線路同 nid 選中／可用狀態、JSON path 當 regex、付費／試看及身份／編碼數值截斷。原生 adapter 按路由區分影片／番劇，catalog 閉包不永久保留 decoder。
- 生產驗證：Debug arm64 xcodebuild 成功；bash Tests/run-w3-sources.sh、bash Tests/run-w2-services.sh、bash Tests/run-work-library.sh 通過。W3 永久回歸涵蓋安全 payload、數值邊界、版本／衝突／啟動／重載保留、來源停用／移除、檔案身份及 HTML／JSON 選集解析；W2 runner 補回生產模組所需 SDWebImage header include。
- 真實兩站比對：Fqdm 海贼王 5917 葉節點／五線，Forest 完美世界 847 葉節點／三線；完整 title、分組／URL／label 順序、current、stream key／index 與遷移前基準完全相同。
- 純配置與播放：編譯後才複製未打包的 Internet Archive JSON fixture，reload 後資訊→MP4 選檔→保存／重讀／再解析；真實搜尋兩頁各 20 筆、下一頁／穩定身份通過，排序避免服務端相關性跨頁重複。Girigiri 原生來源同入口可解析並釋放臨時 decoder。CC-BY 3.0 Big Buck Bunny 經 Processes 啟動 libmpv，416×240、time-pos 3.125 秒後 stop／destroy；隔離原生 App 的現有搜尋頁也完成輸入→選檔 query→流列表→雙擊→實際視窗影格（3.0416667 秒）及停止。
- 逐站與限制：24 個既有 source ID 的現場結果／能力、B23 與番劇變體保存於 .build/w3/evidence，矩陣及使用者來源目錄／重載規則見 FRONTEND_REFACTOR_PLAN §5.1。CC、Douyin、Didahd、Dilidili、Hanime 樣本未完成解析，E-ACG／櫻花未找到本次可用樣本頁；不將失敗全歸因網路。原生番劇 ss959 本次 JSON 解析回 NSCocoaErrorDomain 3840，未提取 playInfo，不宣稱修復原生遠端解析。
- 結案：同步 README／PROJECT／W0 當前狀態／重構文檔；保留建置、回歸、比對、矩陣及影格證據，刪除臨時 runner／SDK／profile／App 複本，停止自有驗收服務。未操作使用者既有 IINA 或資料／憑證。libmpv 視窗不冒充官方 mpv CLI／IINA 應用相容、全部遠端線路或完整彈幕驗收；macOS 13.5／發佈仍未驗證，W2 真實雙帳號／重新授權門檻維持未簽收，W4–W10 未開始。

## 2026-10-08 — 修復影音来源清單中的解析故障並接入熱播

- 修正：嘀嗒 HLS 代理接受現行 ICVE `/rc/` 分段路徑；E-ACG 使用 `/voddetails-`／`/Comicplay/` 與實際 href 線路 ID，所選線路優先；森之屋接受 `hd` 電影 slug 並保留非法路徑拒絕；櫻花新增 yinghuabb 網域／書籤及現行目錄，所選線路優先；Hanime 標題支援現行 h3／meta，保留頁面實際提供的畫質。
- 熱播：新增 Rebo 原生 actor／registry／選集／書籤／本地化／工程及外部播放器接入。僅處理公開 BBA／NBY 的 encrypt=3 token，由隔離站方 WKWebView 取得允許 CDN 的 HTTPS 媒體；捕獲 video src，不要求隱藏播放器完成緩衝。修正 Foundation URL.path 對播放器尾斜線的正規化及實際符合 WKNavigationDelegate 的導覽檢查；不接入網盤／付費／試看或假 fallback。
- 驗證：Debug arm64 無簽署 xcodebuild 成功；`bash Tests/run-w3-sources.sh` 四組通過，新增電影 slug 邊界、新域名書籤與偽冒 host、E-ACG／Rebo 真實線路及集數身份回歸。pbxproj 的 plutil 與 xcstrings 的 JSON 格式檢查通過。臨時隔離程式連結實際建置模組，经 SourceRegistry→VideoDecoder inspect／selection／resolve，而非複製解析器或 mock。
- 真實媒體：嘀嗒 3071 第 7 線第 1 集經實際 NIO HTTP 代理完成 PNG→TS，FFmpeg／libmpv 均可解碼；E-ACG 69000 第 2 集五線、森之屋 2025261963 hd 三線、櫻花 79473 第 1 集六線、Hanime 408446 三個畫質均經 FFmpeg 解碼一秒。E-ACG 所選第 3 線、櫻花所選 sid=7、森之屋首線及 Hanime 1080p 由安裝版 IINA 的無視窗 libmpv 取得非零視訊尺寸且 time-pos 超過一秒。熱播 3832 的 BBA sid=4／NBY sid=5 均通過 FFmpeg 及 libmpv；兩線取消解析均被拒絕，隨後重新解析成功。
- 限制：稀飯 1477 的真實 HTTPS MP4 已解析，IINA loopback video.mp4 是既有外掛啟動佔位；媒體端 play.xfvod.pro:8088 TLS EOF，附 Referer／User-Agent 仍失敗，未宣稱修復播放。櫻花 sid=1 媒體解碼仍失敗；熱播 BBA 首輪媒體失敗／libmpv 逾時，後續通過，不宣稱所有 CDN 每次可用。未做本輪 IINA／mpv 應用視窗、macOS 13.5、內建 JSPlayer、站方彈幕、下載、其他作品／線路及完整播放器相容驗收。未操作使用者既有 App／憑證／資料；同步來源待辦與 W3 能力矩陣，清除自有臨時工具。

## 2026-10-08 — 完成 W4 Bangumi 元資料與帳號接入

- W2 驗收更新：使用者確認 Douyu 帳號正常工作，採納該證據，不重跑真實登入；完整雙帳號／失效後重新授權門檻不自行擴大簽收。
- 元資料：新增 BangumiModels／BangumiService，查核官方現行 API；搜尋分頁、作品標題／別名／封面／簡介／日期／類型／集數、所有類型集數分頁及根路徑 calendar。0 集數為未知，保留官方出處及取得時間；預設 24 小時快取、強刷、帶失敗原因的離線舊資料、取消傳遞。快取按帳號 UUID／guest 分區並接 W2 上限淘汰。
- 本機：Work 的 JSON payload 獨立保存 bangumiMetadata，手動名稱等本機欄位、Episode／已確認來源映射不被外部刷新覆盖。新增本機作品、關聯／解除／更換、保存資料及收藏 ID 排程刷新命令；同名不合併，關聯 revision 拒絕 A→B→A 的舊回應。Core Data v0.4 schema、原書籤與排序不改，清理可重建快取不刪已保存外部快照。
- 帳號：SiteAccounts／AccountHTTP 擴展 bangumi PAT，真實 /v0/me 驗證後才存 Keychain；Bearer 僅送 HTTPS api.bgm.tv，跨 host／非標準埠／userinfo／降級目的地不帶授權。保留 Bili／Douyu Cookie 行為；登出／移除／預設、lease、失效與重新授權共用既有服務。Sites 新增必要 Bangumi 號池 sheet、安全輸入與官方權杖連結；關窗取消授權並在提交前檢查取消，本地化新控制與狀態。
- 驗證：最終 Debug arm64 xcodebuild 成功；WorkLibrary、W2、W3、W4 runner 全通過，包含真實 Keychain 隔離／替換／取消及 Core Data 重開／舊模型遷移。生產模組真實取得葬送的芙莉蓮 ID 400602、2023-09-29 日期、別名／封面／簡介、36 筆所有類型集數，搜尋 total=90、第二頁 offset=10、七天排期；另一真實作品切換／解除不改本機 UUID／來源映射。真實 API 拒絕無效 PAT，未提交憑證或預設。
- 重啟／原生：第二個程序重開真實 API 產生的 SQLite／快取，模擬 notConnectedToInternet 保留原取得時間；清 owned cache 後仍讀保存快照／來源映射。當次建置 App 以獨立 Bundle ID／home 的驗證副本啟動，原生 AX 操作 Sites→Bangumi→新增→SecureField 輸入→真實 401→移除，需授權／No account 狀態及實際視窗 PNG 保存於 .build/w4/evidence/；說明文字實際顯示截斷後已修正換行。
- 限制：未取得或使用真實有效 Bangumi token；有效登入／兩個真實身份／重新授權仍須使用者在 Sites 入口完成，不以注入驗證器或合成凭證冒充。未新增 W5 收藏、W7 搜尋／推薦串接、W9 新產品頁、觀看進度同步或下載／播放器驗收。首次同上游 Bundle ID 的驗證程序遇到既有 Bili Keychain 授權等待，已停止並改用獨立身分；未批准讀取該憑證。臨時程式／App 副本／profile 結案清除，保留去敏證據。

## 2026-10-08 — 恢復稀飯動漫接入與真實媒體取址

- 修正：XiFan 原先把 player_aaaa 的舊 play.xfvod.pro:8088 位址直接交給播放器，實測 TLS 逾時／FFprobe 失敗。站方播放器會經 player.moedot.net 取得另一個 AES-CBC 加密媒體地址；現改讀現行 player_list 配置，處理逗號串接的 downer_list／server_list 邊界，沿用站方 ec.php 及每次回應 UID 的解密方式，交出實際 HTTPS MP4／HLS／FLV。保留作品／線路／集數、付費與試看拒絕、媒體格式與 userinfo 檢查；只接受已核對的解析器 host／路徑，不以移除 8088、換線或假媒體作降級。
- 回歸：新增 XiFanRegression 並納入既有 W3 runner，覆蓋逗號串接配置邊界、獨立加密樣本、回應 UID 換鍵、百分比編碼與 query 保留、站方錯誤、損壞密文、HTTP／帶憑證媒體拒絕。四個來源回歸程式全通過；Debug arm64 xcodebuild 成功，原有警告未在本次擴大處理。
- 現場：當日公開番劇目錄及單集頁可讀；臨時煙霧以實際來源解析今日捕獲的頁面，媒體解析仍連真實站方服務，取得 25 集、舊番主線及封面。生產 AES helper 與 Chromium 執行站方播放器所得地址一致。最終建置 App 的独立 Bundle ID／home 驗證副本經 SourceRegistry→VideoDecoder 的 /video 完整入口解析 1477 第 1、2 集，兩次均 HTTP 200，標題與集數正確。
- 播放：兩集 App 交出的媒體均由安裝版 IINA 的無視窗 libmpv 解碼 1920×1080，time-pos 分別超過 2.002／2.044 秒，停止及釋放成功；首集另通過 FFmpeg 一秒解碼。未以 URL scheme、播放清單 200 或靜態檢查冒充播放。
- 限制：原生介面貼第 2 集網址後顯示 Plugin not installed，未安裝或修改使用者 IINA 外掛，故不宣稱 IINA／mpv 應用視窗通過。3166／3541 新番目錄可讀，但部分播放頁仍逾時或返回站方 SQLSTATE／資料庫 DNS 錯誤；未宣稱全部作品／線路可用。內建 JSPlayer、站方彈幕、最低 macOS 與其他站點未在本輪驗證。
- 記錄與清理：更新 websitesforanime.md 及 W3 來源能力矩陣；保留去敏驗證記錄／本機外掛缺失畫面於 .build/xifan-repair，停止自有 App／瀏覽器並移除臨時程式、副本、profile、密文與媒體地址，不清除使用者書籤、Cookie 或偏好。

## 2026-10-08 — Bangumi 個人 OAuth 登入與單帳號切換

- 按使用者修正：開發者平台 token 不是個人帳號憑證。新增 `BangumiOAuth` 授權碼／refresh token 流程，隱式使用提供的 app 配置，不再要求建立或貼上平台／個人 token。使用非持久 WebView，明確送出 `iina-ani://bangumi/oauth` 回調並核對目的地、state、重複／缺漏參數；code 換使用者 token 後通過 `/v0/me` 才提交。
- Bangumi 只保留一個個人登入身份：移除選帳號、新增、啟停、設預設及移除帳號 UI，保留登入／重新授權、刷新及登出；Bili／Douyu 號池不變。取消或初次登入失敗不留下空帳號；重新授權失敗保留原憑證，成功替換同一身份的兩種 token。
- access token／refresh token／到期時間只存 Keychain，偏好僅存單帳號 UUID／狀態／名稱。到期可刷新續期；區分網路／伺服器錯誤與失效 grant。遷移沿用原選定帳號，不刪除其他舊憑證，也不在登出或重啟後自行啟用它們；登出清除當前 token 並換新 UUID，隔離下次登入與上一身份快取。
- 驗證：最終 Debug arm64 `xcodebuild` 成功；`run-w2-services.sh`、`run-w4-bangumi.sh` 通過，覆蓋單帳號建立／拒絕／重新授權／lease／持久化／取消、OAuth 回調與 state、續期失敗保留／成功輪替、遷移及登出。生產 OAuth 程式連真實 token 端點，無效 code 返回 HTTP 400 `invalid_grant`，沒有提交憑證。
- 原生 smoke：啟動最終 App 的獨立 Bundle ID／home 副本，實際確認無號池控制、開啟官方個人登入頁、取消後仍未授權；保留去敏日誌及單帳號頁 PNG 於 `.build/bangumi-oauth-smoke/evidence/`，建置日誌為 `.build/bangumi-oauth-build.log`。更新 README／PROJECT／重構文檔及本記錄；停止自有副本，移除臨時程式、驗證 App／home、原始授權 HTML 及過時畫面。
- 邊界：未完成真實有效個人登入／同意授權或真實 refresh token 續期，離線 fixture 不冒充此證據。桌面內置 app secret 可被提取，隱式配置不等於伺服器端保密；不在文檔／日誌重述 secret。未新增播放來源、收藏或進度同步。

## 2026-10-09 — 修正 Bangumi 登入返回地址丟失回調參數

- 使用者回報仍返回 `invalid_uri / No redirect URI was supplied or stored`，按失敗事實追查，不以重送無效 code 確認問題。實際網站的未登入 `/oauth/authorize` 重定向生成的 `chii_referer` 只保留 client_id／response_type／state，省略 redirect_uri；另以原生 WebKit 發現未完全編碼的登入返回 query 被截斷。
- 修正 `BangumiOAuth.Attempt`：以 `loginURL` 取代直接授權入口，先開官方 `/login`，將完整授權返回地址置入 chii_referer；內層 callback 與外層返回地址分別按 RFC 3986 query value 字元完整編碼，固定 callback 的編碼只計算一次。WebView 遷移唯一呼叫端；沒有在回調階段補 state、吞錯或要求個人手貼 token，應用憑證／單帳號／Keychain 提交規則不變。
- 實測：最終 Debug arm64 建置及 W2／W4 runner 通過。以生產 loginURL 載入真實官方頁的原生 WKWebView，斷言登入表單提交的 referer 與完整授權返回地址相同、callback 及每次 state 完整；修正前此檢查失敗，修正後通過。此外部網站行為以現場 smoke 驗證，不新增 URL 字串／轉發副本類永久測試。
- UI：最終 App 的獨立 Bundle ID／home 副本經 General→Sites→Bangumi→Sign In 實際打開個人登入頁，取消回到單帳號未授權狀態。未讀取／記錄密碼、Cookie 或授權碼，保留去敏日誌及取消後 PNG 於 `.build/bangumi-redirect-fix/evidence/`。更新 README／重構文檔／本記錄，停止自有副本及瀏覽器，移除臨時程式、App／home 與原始診斷參數。
- 驗收邊界：現在證據覆蓋登入表單提交的完整返回地址，不再以「登入頁打開」或 HTTP 400 invalid_grant 代表整段授權完成。仍未取得真實有效個人授權碼／token，未宣稱登入同意授權或真實續期已驗收；既有使用者資料與 Bili／Douyu 帳號不變。

## 2026-10-09 — Bangumi 登入修正通過使用者實測

- 使用者回報「已測試可行」，確認本次 Bangumi 個人帳號 OAuth 登入／回調丟參修正可用。此結果補充上一筆本機驗收邊界：登入可行性現已有使用者現場確認，不以離線 fixture 或僅打開登入頁代替。
- 驗收來源為使用者實際測試；依回報保存結果，不重跑檢查，不延伸宣稱真實 refresh token 續期已驗收。本次僅追加工作記錄，未修改程式、帳號憑證或使用者資料。

## 2026-10-09 — W5 收藏、來源身份與舊書籤遷移完成

- 交付 `FavoriteLibrary` 及 Core Data Library v0.5：作品以本機 Work UUID 收藏／去重、保留可選 Bangumi 關聯、明確確認多來源；連結保留原 URL、來源 canonical identity、獨立標題與時間。兩類提供各自查詢／排序／移動／修改／刪除命令；同名／同 Bangumi ID 不合併本機 Work，不自動將單集、直播或普通影片升格作品。
- SourceRegistry 的同步離線頁面 identity 同時供收藏與 VideoDecoder 選擇使用，保留 Bili 分 P／festival 與配置來源 query；未知／失效頁可存取並編輯，b23 離線不猜測長鏈。既有 DataManager 書籤命令切換同一存儲，原生 Add 成功才 dismiss；新 Bookmark 初始化 AppKit 所用的 title／name cache，避免遠端刷新前空行，不覆蓋匯入列或手動收藏標題。
- `BookmarkFavoritesMigration` 在開庫升 schema 前以 SQLite backup API 保存包括已提交 WAL 的一致快照，旁置 `<store>.w5-backup/backup.sqlite`，私有目錄及既有備份不覆蓋。遷移保留原 URL／liveTitle／remark／Double 排序及舊重複列，新增 UUID／canonical／來源／匯入時間；完成版本以 explicit save request 立即持久寫入 SQLite metadata，不等下一次使用者寫入。冷還原先驗證備份並要求所有 coordinator／App 關閉，原子替換而不消耗備份；回退會丟棄備份後修改，README 已明載。
- 驗證：最終 Debug arm64 建置及公開 `run-w5-favorites.sh` 通過；WorkLibrary、W2／W3／W4 回歸與生產來源／播放頁 identity smoke 通過。實際 v0.3／v0.4 SQLite 的 WAL 備份、無損遷移、重複開庫、新增去重、還原後旧 model 重讀／再遷移、開庫還原拒絕、SQLite trigger 強制 save 失敗／回滾／再試、空庫版本與未來版本保護已執行；預期故障產生的 Core Data error log 不是未解失敗。
- 跨程序 smoke：第一個程序保存一個 Work 收藏／兩個來源與離線連結，實際 UUID 交給 BangumiWorkSync 回傳 unlinked；第二個程序重開、修改連結及移除收藏，Work／來源映射仍在，完成媒體檔與獨立帳號資料 fixture 位元組不變。作品／Episode／來源映射刪除隔離另由真實 Core Data 回歸覆蓋。
- 原生 smoke：獨立 Bundle ID／home 的 App 對舊庫副本顯示普通影片、分 P、直播、劇集與失效 URL，正常退出／重啟後 5 筆 UUID、標題、原 URL、小數排序與 version=1 完全一致。AX 實際輸入網址／按 Add／關閉 sheet；最終副本的 WindowServer／AX 未列出其 NSWindow，改由 debugger 操作同一生產 controller／text field／IBAction，保存 p=2／p=3 並關閉 sheet，再讀實際 SQLite。最終 NSView cacheDisplay render 證明刷新前網址標題非空，刷新後顯示實際 Bili 標題；此 PNG 非桌面截圖，未更換介面或使用 mock。
- 記錄與清理：更新 README／PROJECT／重構文檔及本記錄，保留去敏記錄、舊库 window screenshot、最終原生 view render 於 `.build/w5/evidence/`；關閉自有 App／debugger，移除臨時程式、模型、App／home、資料副本及遞迴 AX 診斷輸出。沒有遷移現用資料庫、移除使用者帳號或觸碰使用者播放器。
- 範圍：W5 後端完成；雙欄 View／可調欄寬屬 W9，完整搜尋／收藏串接屬 W7，真實下載屬 W6。檔案／帳號 fixture 不冒充 W6 任務或有效授權；未新增觀看進度同步，未驗证最低 macOS。保留既有 Bangumi 使用者登入確認記錄，不延伸其續期驗收。

## 2026-10-09 — W6 真實下載、恢復與完成檔播放完成

- 新增 `DownloadModels`、`DownloadSourceResolver`、`DirectDownloader`、`HLSDownloader`、`DownloadService` 並納入 App target。任務 owner 提供排程、快照／事件、明確狀態／允許操作、原子私有 JSON／writer lock、目錄／bookmark／併發策略、帳號 lease、暫停／取消／正常或強制退出恢復；不保存短效媒體 URL／Cookie，不自動重試、換帳號、來源、集數或降低品質。
- 直連以串流寫檔及 strong ETag／原 URL hash／完整 Content-Range 驗證安全續傳；無法證明身份時明示重下載。HLS 順序下載全部 TS／fMP4、key／MAP／BYTERANGE、AES-128／IV 與主清單分離音訊，恢復保留變體身份但從頭下載分段；有限非 DRM 基線才接入，直播／DASH 分離／Didahd 代理／local 等不宣告可下載。FFmpeg 只接收本機私有清單，stream copy 成 MKV 並驗證解碼，不重造通用解封裝器。
- 真實完成與檔案命令：exclusive rename 不覆寫、長 Unicode 標題限制檔名 bytes；刪記錄保留完成檔，刪檔為獨立命令；`Processes.shared.openDownloadedFile` 經既有 IINA／mpv 路徑開啟。App 正常退出保留原 Core Data 保存／取消確認，之後等待下載 writer 停止；启动將中斷工作標待恢復，新頁與 Finder 按鈕留在 W9。
- 執行證據：最終 Debug arm64 xcodebuild、`Tests/run-w6-downloads.sh` 與受影響的 W3 runner 通過。W6 實際 HTTP／檔案／程序回歸涵蓋 Range／ETag 身份及精確 bytes、未知總量、Referer／Cookie 重定向邊界、401 後原選擇重解析、lease、偏好快照、取消／刪除隔離、碰撞／Unicode、真正子程序強制／正常退出和重開恢復；真實 FFmpeg／FFprobe 覆蓋 AES 非零隱式 IV、fMP4 MAP、隱式 byte range、分離音視訊、主變體消失及最終傳輸／全部段數。
- 公開媒體 smoke：Internet Archive 配置／生產解析器下載 Big Buck Bunny MP4；公開 Mux test_001 全部有限 HLS 下載與封裝、暫停／從頭恢復、封裝拒絕取消。完成檔透過實際 `Processes.openDownloadedFile` 啟動安裝版 IINA 的 libmpv helper，播放超過一秒、定位尾段繼續播放並 destroy；尺寸／時長／time-pos 見重構文檔與播放器 JSON。最終 HLS 完整 51 段／67,321,296 媒體 bytes，不把封裝檔大小當傳輸量。EACG 原第 3 線第 2 集 239 段後網路中斷明示 network；原任務另由生產解析器重解析且保持所有選擇，重新取得 key 後暫停／取消，未宣稱該集下載完成，也未把 Mux 當成其 fallback。
- 真實異常：24 MiB HFS+ 磁碟映像承載 32 MiB HTTP 下載回 diskFull；系統唯讀路徑回 directoryNotWritable。清理可重建快取保留活動 writer，已有媒體／同名 sentinel 不變且完成檔取不同名稱。驗證捕獲並修正既存目录 bookmark URL 尾斜線比較、完成進度回呼晚於 writer、Unicode 檔名及 FFmpeg 跨執行緒 Foundation waitUntilExit 卡住；最後將 FFmpeg 啟動／讀取／等待放在同一 utility 執行緒，真實回歸與公開 HLS 再次完成。
- 文檔／界限：README、PROJECT、重構狀態／能力矩陣及本記錄已更新，FFmpeg helper 搜尋、缺少工具錯誤、架構／dylib／最低系統／LGPL／GPL 打包要求已載明。本輪為無視窗 libmpv 解碼，不冒充官方 mpv CLI 或 IINA App 視窗相容；未測 macOS 13.5、未捆綁 Homebrew binary／完成正式 fork 發佈。lease／401 合成帳號是邊界測試，W2 既有有效雙帳號／重新授權門檻與使用者登入確認均保留。去敏日誌、任務與公開完成媒體／播放器 JSON 保留在 `.build/w6/evidence/`，驗證後移除自有暫存程式／資料並卸載磁碟映像；不操作使用者現用資料庫、帳號或播放器設定。

## 2026-10-09 — W7 搜尋、日常更新與指定清單功能串接

- 範圍：按使用者提供的 css1.json 核對 18 項／17 個既有來源，Hanime 兩檔共用來源身份；新增下載只做該清單，Bilibili 額外接搜尋而不擴充 Bili／Douyu 下載。清單站沒有網站帳號提供者，保存 guest，不建立假登入、轉用其他站 Cookie 或匯入任意腳本／媒體規則；原 M2 有效帳號下載門檻保留。
- 搜尋：新增 BrowseSearchService、SourceSearch 共用解析與原生搜尋資料，納入 App target。Bangumi／來源結果及來源種類分離、啟用來源篩選、原查詢固定、独立分頁／去重、空與錯誤分離、錯誤保留此前結果；URL 不經 Bangumi。owner 持有／取消真正 worker，避免取消或新查詢後的舊結果回寫；沿用 VideoDecoder.inspect／catalog 的原選擇與帳號 pinning。
- 日常：DiscoveryService 輸出排期、收藏實際新增集及有理由／待確認的當季同名候選；Bangumi 季度資料為每月首 100 筆、前三個月的有界樣本。已見身份以私有原子 JSON 留在 Application Support、可重建快取以外；首次、重排、移除再加入不誤報新集，存檔失敗不消耗事件。App 啟動／前景／跨日共用每日快照，進行中跨日通知留待刷新，退出取消／等待 worker，不加輪詢或新 UI。
- 來源：Fqdm／Forest 沿用配置／帳號安全規則；搜尋新增欄位通過嚴格白名單。海星現行 lpic 列及零起始 pageindex 修正，服務游標仍從 1 起；驗證頁拒絕選擇器不冒充空結果，櫻花／熱播採已核對現行域名。Bilibili 使用提供的官方搜尋頁／非持久訪客 WebKit origin 執行官方影片分頁，不使用登入容器，實際兩頁結果可回既有解析、品質準備及播放器。稀飯依站方 EcPlayer1.js 修復 type=auto 與 type=0 同一 AES-CBC 契約，保留所選第二線／第 2 集；回歸使用獨立密文覆蓋。
- 功能煙霧：真實 Bangumi 葬送的芙莉蓮 400602 → 稀飯來源搜尋／目錄 → 明確來源／Episode 映射 → 第二條備用線第 2 集 → 实際 libmpv NSWindow 影格／尾段播放 → 收藏。第二程序重開 SQLite 並核對 UUID、保存元資料、映射／品質／guest，重新解析原選擇並再播。普通 Archive URL 在 Bangumi transport 強制離線時仍可解析／播放／收藏／第二程序再播；Bilibili 亦完成真實關鍵詞兩頁、普通 BV URL 準備／影格／尾段及連結收藏。
- 下載煙霧：生產服務／解析器建立既有 Archive 直連與原稀飯 HLS 任務，實際寫入後暫停／正常退出；活動 HLS 改目錄、清可重建快取仍保留原目錄／暫存／writer，第二程序重開並重新解析原選擇、完成直連 43,315,070 傳輸 bytes 與 HLS 306／306 段、486,921,692 傳輸 bytes；兩完成檔均由 Processes.openDownloadedFile 實際解碼、視窗影格及尾段播放。沒有把基線 Archive 新增成內建站點。
- Didahd：新增精確 owned／有效期／端口／路徑驗證，只讓該來源的已註冊 PNG→TS 清單走既有 HLS，無 Cookie／任意 localhost；實際任務讀取 379／552 段後 failed/mediaUnavailable，原身份保留，未改來源或聲稱完成。另公開目錄樣本回 notFountData，本輪亦未播／完成。
- 日常及逐站：真實 DiscoveryService 取得今日 14 筆排期、收藏首次 0 更新／推薦 0，持久基線與同日重用；實際 Bangumi 七日及當季樣本 122 筆。17 站逐一記錄結果／空／失敗，10 站取得來源項目，5 站次頁取得新身份；4 站 403，風車安全驗證／Hanime 格式失敗。Girigiri 靜態回空但瀏覽器另導向 502 主機，未宣稱健康或搜尋可用。
- 回歸與界限：Debug arm64 建置、W3／W4／W5／W6／W7 runner 通過；新增行為回歸涵蓋查詢／分頁／底層取消、完整配置載入、URL host／編碼、標題／連結、零起始頁码、驗證與空、持久更新一次、固定日期／時區／故障／取消。帳號 lease 拒絕移除仍為实际服務 fixture，不冒充有效網站帳號。播放器證據是安裝版 IINA 的 libmpv render API／臨時原生 NSWindow，不宣稱官方 IINA／mpv CLI、最低 macOS 13.5、完整彈幕或正式打包已驗收；原 M2 未全通過，不自行開始 W8／W9。
- 記錄：README／PROJECT／重構文檔／來源記錄同步；去敏日誌、身份與播放器 JSON、影格／原生主視窗及完成媒體留在 .build/w7/evidence。結案移除臨時程式、驗證 App／profile、原始頁面與带簽名媒體日誌，停止自有程序；不清理使用者現用資料。
- 最後原生回歸定位 Bilibili 訪客從搜尋頁導向 www.bilibili.com 被過窄規則攔截；只放行兩個官方 HTTPS 主頁、取消新視窗，未放寬到其他來源／登入域。移除臨時診斷後重新建置及 W7 三組回歸通過，實際查詢首頁 20 筆、独立查詢取消、第二頁累積 32 個不同身份、既有影片準備／65 個視窗影格／633.366 秒尾段與連結收藏通過。

## 2026-10-09 — Animeko Torrent 來源與下載播放模組審查

- 新增 `docs/research/ANIMEKO_TORRENT_REVIEW.md`，固定上游 open-ani/animeko 提交 `3e3c22c91b2019504cb9f8e33e9749d37162b45c`，涵蓋 Mikan／DMHY 搜尋、身份／去重、選檔、Anitorrent／PikPak、piece／seek、逐集快取、恢復／關閉、平台與授權，以及 IINA-ANI 的接入邊界；保留舊 Animeko-review，不沿用未核實的歷史結論。
- 實際執行：以 Kotlin CLI 2.2.21／JDK 25.0.1 原樣編譯上游四份 api/pieces Kotlin 原始碼，隔離煙霧觀察非首塊完成仍補後方 piece、prefetch 去重／範圍過濾、possibleFooterSize 變更不影響該場景；已完成 piece 在訂閱前發出通知會等待至 200 ms timeout，訂閱後再通知則返回。文檔明確區分邊界實測與真實播放器／native 後果推論。
- 文檔檢查：28 個固定 commit 的來源引用均對應 checkout 的實際檔案，引用標籤、本地文檔連結及程式碼區塊配對通過；共 11 節、8 項風險／契約發現。
- 限制：未跑上游 Gradle／正式測試、網站在線驗證、真實 BT／PikPak／播放器或跨平台驗收；上游 catalog 使用 Kotlin 2.4.10，隔離編譯不冒充完整鎖版建置。沒有修改 App／上游生產程式、下載範圍、W2／M2 驗收或使用者資料；審查完成後移除自建 checkout、編譯器與煙霧暫存。

## 2026-10-09 — 新增 Torrent 支援目標與 W11 計畫

- 依使用者決策，在 FRONTEND_REFACTOR_PLAN.md §4.8／§5.4 加入 Torrent 下載與邊下邊播，固定 libtorrent-rasterbar 2.1.2（tag v2.1.2／commit 6da363d2994f17c0b3c0450d124cf73a31a73847）。W11.1 原生核心、W11.2 任務與恢復、W11.3 Range／播放器、W11.4 產品整合，全部未開始；MT1–MT3 為新增驗收關卡，W10／M4 總結案納入 MT3。
- 定義 magnet／本機 torrent、多檔精確身份、v1／v2-only／hybrid、DownloadService 單一 owner、NIO 受控串流、共享使用權、缺塊 seek／取消、resume、路徑／刪除隔離、上傳政策、macOS 13.5、架構與授權／簽署門檻。網站搜尋適配與核心分離，不自動加入 Mikan／DMHY、RSS 或其他網站下載。
- 保留 W0–W10 歷史與 W2／原 M2 未簽收範圍；核心可先做，Torrent UI 仍待原 M2 與 MT2。同步 README、PROJECT、共用 UI 整合要求、總驗收旅程與風險表，不另建計畫文件。
- 實際驗證：三份目標文件的本地 Markdown 連結、程式碼圍欄配對、無 NUL、固定版本、§4.8／§5.4、四個 W11 子包及 MT1–MT3 定義檢查通過；依既有文檔規範不執行 App 建置／測試。
- 限制：本次僅修改計畫與說明，沒有新增依賴或生產程式。前次 libtorrent 2.1.1 binding 的 loopback 傳輸／resume 序列化煙霧只作選型證據，不冒充 2.1.2 原生建置、App 播放、程序恢復或最低系統驗收。

## 2026-10-09 — 完成 W11.1 原生 Torrent 核心與橋接

- 交付：新增 `Native/deps.lock`、C++17／CMake 增量建置入口及 Xcode native phase，固定 libtorrent-rasterbar 2.1.2（6da363d2994f17c0b3c0450d124cf73a31a73847）、try_signal 子模組、Boost 1.89.0、私有 CMake 3.31.8 與 archive SHA-256。原生靜態庫按 arm64／x86_64 分開產出；App 與 native 明確固定 deployment target 13.5。建置使用 macOS kernel file lock，避免中斷留下死鎖目錄。
- 所有權：薄 C ABI 保留 C++ exceptions／記憶體在 native 邊界；`TorrentSession` actor 持有 opaque owner、無全域自動啟動 session。單一消費者取得複製 alert 值，native poll 排空現有批次後才取下一批並重用暫存；verified bytes 按已校驗 piece 計。取消清掉 handle／排隊事件但不刪檔；關閉等待 session_proxy 及 disk workers，Swift 顯式 close 可重複，析構亦釋放。
- 真實執行：`Tests/run-w11-torrent.sh` 載入這份 Debug App 的 dylib，透過實際 Swift／C ABI 驅動 2.1.2 兩 peer。自建 v1 fixture 三輪各完成 4,194,427 bytes，逐 byte 相同，SHA-256 均為 `3b1695b0bcd6e302bfbe97df367e770aa29e4005f98f99b77892a2b010b9508b`；peer／finished alerts、完成後取消保留檔案、取消／重新加入、關閉後拒絕命令、十輪 idle 啟停與重複 close 通過。runner 結束清理隔離 fixture／home，未使用網站內容或 Python binding。
- 其他驗證：App Debug arm64 建置；原生 arm64／x86_64 建置與 Mach-O minos 13.5／架構檢查通過。原生 fixture dylib 只含系統 CoreFoundation、SystemConfiguration、libc++、libSystem；App 沒有新增第三方 Torrent／Homebrew dylib。三份上游 license 已進入 App Resources。工程 plist 檢查、kernel lock 競爭／釋放煙霧及既有 `run-w6-downloads.sh` 真實 HTTP／HLS／程序恢復回歸通過；W2–W7 App 模組 runner 補上 native module include。
- 邊界：W11.1 限 loopback、關閉 DHT／LSD／UPnP／NAT-PMP，禁止 tracker／web-seed 與非 loopback peer；TLS／HTTPS tracker 未编入。DownloadService 任務、magnet、精確選檔、resume、Range／外部播放器與 UI 是尚未開始的 W11.2–W11.4。未實測 Intel／macOS 13.5、App Torrent UI（尚不存在）、簽署／公證或完整網站回歸；未把 native 建置冒充最低系統執行。README、PROJECT、重構文檔已同步 W11.1 驗收；MT1–MT3 與原 W2／M2 關卡保留。

## 2026-10-09 — 完成 W11.2 Torrent 任務、選檔與恢復（MT1）

- 交付：DownloadService 接入 magnet／本機 `.torrent` metadata、明確非首影片選擇、同 swarm 共享 transfer、P2P 確認／最小有效上傳上限、暫停／取消、原子 metadata／resume 附件與正常退出 writer join。目錄快照、bookmark、完成檔發布及刪記錄／刪檔維持 W6 契約；沒有另建任務資料庫或 UI。
- 身份：算法標記 v1／v2 hash 集合、file index、路徑、大小共用於原生來源、下載、收藏及 Work／Episode 映射。保留 native 來源 ID，拒絕未選檔的 magnet／torrent 收藏與編輯，不把 tracker 敏感參數保存成收藏身份；實際 Core Data 重開維持精確選檔。
- 原生修正：magnet metadata-only 不使用會提早暫停的 stop_when_ready，明確選檔才解除 upload_mode。已知／持久 metadata 重用，避免同 swarm 重複 peer 連線。v2 sparse Merkle tree 只進 resume，不匯出為完整 piece layer；初始 fast-resume 期間 force_recheck 會被上游忽略，故載入時清除被信任的完成 bits，由真實檔案重新校驗。這採用較保守的重開磁碟校驗，而非無條件相信舊 bitmap。
- 真實驗收：載入 Debug App dylib 的 `run-w11-downloads.sh` 完整通過，包含自建 35 秒 FFV1 素材的 v1／v2-only／hybrid 多檔選非首影片、完成檔 `fileForOpening`／ffprobe／SHA-256、部分下載正常程序退出與真實 SIGKILL 後重開、共享使用者與 metadata 取消隔離、目錄偏好切換、外部 symlink sentinel、獨立刪記錄／刪檔。v2-only／hybrid 的有效、缺失、損壞 resume 均先修改 private payload，再驗證修復後精確雜湊；private hybrid 以本機 torrent 傳輸，不繞過禁止 private metadata exchange 的規則。
- 失敗／安全驗收：無 peer metadata 四秒有界返回；專用 64 MiB HFS+ 映像實際寫滿得到 ENOSPC／diskFull，沒有填滿系統卷。native smoke 通過零上傳速率拒絕、16 KiB/s loopback 限速、原始 traversal／絕對路徑／symlink metadata 拒絕、writer-drained pause／remove。100 MiB metadata 與 FIFO 在讀入前拒絕，該 smoke 的峰值 RSS 增量為 147,456 bytes。
- TLS／建置：OpenSSL 3.5.8 與 CA 校驗／授權隨包，HTTPS tracker 的受控可信 CA 成功、未信任憑證失敗；公開 session 啟用 discovery，已知 private 禁止 DHT／LSD／PEX，web-seed 關閉。App Debug arm64 與最終 native arm64／x86_64 建置通過；x86_64 fixture minos 13.5、僅系統 dylib，沒有新增 Homebrew／OpenSSL／Torrent 動態庫。
- 回歸：`run-w11-torrent.sh` 三輪各 4,194,427 bytes、SHA-256 一致及十輪啟停通過；`run-w3-sources.sh`、`run-w5-favorites.sh`、`run-w6-downloads.sh` 全部通過。原始 magnet 收藏的永久回歸已觀察失敗前／修正後；W5 遷移故障注入仍正常通過。README、PROJECT、重構文檔同步 W11.2／MT1 證據。
- 邊界：W11.3 Range／IINA／mpv 邊下邊播、W11.4 UI、MT2／MT3 未開始。Intel 實機、macOS 13.5 執行、正式簽署／公證未驗證；W2／原 M2 帳號門檻未改變。

## 2026-10-09 — 完成 W11.3 Range 串流與外部播放器（MT2）

- 交付：native reader／request token、集中 piece alert 分派、缺塊 deadline 與已完成塊讀取；Swift detached read 的 owner lease 保證取消及退出不使用已釋放指標。按 piece／file 邊界最多讀 256 KiB，不讀 sparse 零值；32 readers／session、16 MiB piece 上限，完整 piece 暫存最壞上界 512 MiB。
- HTTP：沿用 NIO loopback；完整 GET、HEAD、單一閉區間／open-ended／suffix、206／416／精確 bytes 通過，多 Range 明確忽略後回 200。256-bit 短效 token 綁定選檔，六小時硬到期；32 grants／32 requests，有界 chunk 與 NIO 背壓。授權與每 request 獨立 lease，斷線、撤銷、到期及 App 退出釋放等待；不保存或記錄 URL。
- 整合：DownloadService 是唯一持久任務 owner，新增既有任務及純播放選檔授權；TorrentTransferPool 合併下載／reader 使用權。Processes 的 IINA／mpv 播放透過私有 Unix IPC 觀察 loaded／end-file／斷線，停止只作用於該播放；不以短命 iina-cli 程序或 URL scheme 成功代替生命週期。取消的 native 讀取正確保留 CancellationError，而不是冒充 network。
- 真實驗收：App-linked 自建 600 秒、99,533,414 bytes FFV1 hybrid 多檔影片，選 metadata index 2，seed 限速 512 KiB/s。IINA 1.5.0／mpv 0.41.0 各自實際開窗；先確認 owned 檔案中 300 秒／570 秒對應區域尚未下載，再 seek，IPC time-pos 越過 301／571 秒後繼續前進。最終 mpv 中段 301.042→301.667、尾段 571.083→571.625；IINA 中段 301.167→301.667、尾段 571.042→571.583。停止兩播放器後授權 URL 均回 404。
- 共享與 HTTP 煙霧：同塊雙 reader 其中一個斷線，另一個仍取得精確 bytes；撤銷一個授權保留另一個及獨立下載，取消下載仍可透過 reader 讀完整內容。完整／suffix／開放尾端／任意 offset、416、無授權 404、HEAD 忽略 Range、多 Range 全檔 200 都經真實 HTTP 比對。測試在 seek 前檢查缺塊，避免將 libtorrent 已預取區域誤算成缺塊驗收。
- 建置／永久回歸：最終 Debug arm64 App、native arm64／x86_64 通過；x86_64 fixture minos 13.5、動態依賴只有系統庫。run-w11-torrent.sh 三輪精確 4,194,427 bytes／SHA-256，包含 reader 取消、已完成塊 offset／EOF；新增 run-w11-http-range.sh 17 個 Range 邊界案例通過。run-w6-downloads.sh 的真實 HTTP／HLS／恢復與 W112_PHASE=sharing-v2 的共享暫停／取消通過。
- 證據與清理：安全日誌及獨立測試播放視窗截圖在 .build/w11.3/evidence；臨時 smoke runner、fixture、隔離 home 與下載資料已清理。測試主機安裝 Homebrew mpv，連帶更新其 FFmpeg 等依賴；App 原生依賴仍固定 Native/deps.lock，未捆綁 Homebrew 庫。README／PROJECT／重構文檔同步 MT2。
- 邊界：W11.4／MT3 與 Torrent UI 未開始；JSPlayer 不開放 Torrent。Intel 實機、macOS 13.5 執行、正式簽署／公證尚未驗證；原 W2／M2 帳號關卡不變。

## 2026-10-10 — 依賴结构整理與單元驗收政策切換

- 委派：指定的 `6.1Sol` 未註冊，啟動前即被工具拒絕；經使用者明確選擇後改用兩個 `task` subagent，分別實作 HTTP 生命週期／注入路由及來源依賴一致性；主線負責組裝、編碼、儲存、呼叫端遷移與編譯整合。未將 task 冒稱為 6.1Sol。
- 結構：AppDelegate 擁有 AppServices，集中播放器／下載／HTTP／串流依賴與關閉。Processes 不再是 singleton 容器；VideoInspectionSession 改由各畫面持有，搜尋服務由工廠按畫面建立。HTTP、彈幕與資料刷新接受明確依賴。
- 服務：HTTP start 可等待、可失敗並回傳實際端點；共用並行啟動、等待連線關閉與埠釋放。Huya／Didahd 使用有效端點，Didahd 按 session 保存端點驗證。移除未啟用且回傳空字串的 DASH 註冊路徑，以及已無路由使用、可能刪除保存 XML 的舊 WebFiles 複製步驟。
- 資料：VideoDecoder 注入 registry／accounts／啟用策略；DownloadSourceResolver 從同一 decoder 取得上下文，Discovery 的集數身份規則移至來源層。YouGetJSON 保留媒體資料，PlaybackPreparation／PlaybackEncoder 分離檔案準備與既有外掛編碼，保留選線、XML 優先與 wire format。AppStoragePaths 保留原目錄佈局，持久任務不再由圖片快取推導或降級到 temporary directory。
- 編譯：Debug App `xcodebuild` 通過。整合過程修正 subagent 的 Swift 範圍編輯與 NIO typed bind 問題，並修正組裝根的型別推導／初始化隔離。
- 使用者限制更新前已執行：HTTP 生命週期／播放編碼、W2 帳號／偏好、W3 來源、W7 搜尋／Discovery、W11 Range、W6 HTTP/HLS 下載及 W11.2 本機 Torrent peer 回歸通過。原生 App 主視窗及設定視窗曾開啟，已正常退出；不宣稱完整 UI 驗收。
- 限制更新前的端到端 smoke 在本地 file URL inspect 遭 notSupported 處停止，尚未啟動計畫中的 mpv 實播。根因是 registry 將本地身份交給需要 host 的 native URL 分類；已修正統一 local 分類與免帳號 catalog 路徑，並新增 inspect(file URL)／catalog 單元回歸。修正後依最新要求不再重跑端到端 smoke。
- 最新單元驗證：`bash Tests/run-dependency-regression.sh --unit` 通過播放編碼、來源 registry（含本地身份／inspect）、17 個 HTTP Range 邊界及偏好／下載策略快照。入口預設僅單元；實際 listener 生命週期測試留在手動 `--integration`，本次政策切換後未執行。
- 邊界：使用者於本輪要求 UI 重構完成前不做整體測試，故後續只保留單元與必要編譯；未完成的 App／IINA／mpv／站點／傳輸整體驗收延後，不宣稱本輪整體通過。已移除臨時 smoke 程式及其暫存資源，未清除使用者資料或改動既有帳號。README、PROJECT、前端工作文檔及 AGENT 已同步此政策。

## 2026-10-10 — osu 方法研究與組件／Skin 規劃擴充

- 研究：固定 osu-framework cdd182d326f62f659cbbf6a68b3b67202132043b 與 osu adfbb1ca25f7836f0f3577faac334469e6e9e8ae，透過 GitHub tree／原碼閱讀 ResourceStore、TextureStore、流式／網格容器、Skin 查找／切換、.osk 匯入／ZIP 匯出、佈局序列化及撤銷。Context7 輔助定位，來源與逐項取捨寫入重構文檔 §6.3.1；沒有把遊戲層 Skin 能力誤歸 framework。
- 決策：沿用原生 UI 與既有服務，Skin／Layout／功能偏好分離；共用穩定組件身份、可拖曳與鍵盤編排、非基礎功能啟停、受限 JavaScript 生成同一 Layout、.iinaskin 素材／樣式分享、固定恢復入口及淺層設定。腳本隔離是本專案待實作要求，不是 osu 的已證明能力。
- 文件：重構規劃同步需求矩陣、排除範圍、依賴、W8.1–W8.4／W9、§6.2–§6.5、§8.1 旅程 10–14 與風險；README／PROJECT 同步產品範圍，原先不做拖曳／佈局腳本的限制由新決策取代。
- 邊界：本次僅研究與文檔，不複製上游程式／素材、不加入依賴、不啟動 osu 或 IINA+、不執行建置／單元／整體測試。W8–W10 仍未開始，腳本引擎／限制與包資源上限須在各實作子包驗證；原 M2 未簽收項及 UI 完成前暫停整體驗收政策保留。
- 文件檢查：17 個固定 SHA 來源引用全部對應本次成功取得的原碼／授權檔；核對 §5.3、§6.3.1–§6.3.7、§6.5 與 §8.1 新旅程的章節位置。搜尋 FRONTEND_REFACTOR_PLAN／README／PROJECT，舊「本階段不做拖曳／主題可視化編輯器」限制已移除；無限制腳本與來源腳本仍明確排除。未把文檔檢查當作 UI 或沙箱運行證據。

## 2026-10-10 — 重整前端重構規劃的正文與證據導覽

- 結構：新增閱讀導覽與 §0 現況／驗證政策／維護規則；§5 集中工作包、依賴與關卡，不再穿插歷史長表。10 段 W1–W7／W11 證據搬到附錄 A，osu 固定版本及 Torrent 前期選型研究搬到附錄 B；正文保留摘要與直達連結。
- 語義：保留正文 §1–§9、W0–W11、M1–M4、MT1–MT3 編號與既定範圍；原 M2 未簽收及 UI 完成前只做單元／必要編譯的政策不變。把實播／整體驗收要求明確標為恢復驗收後執行，並集中現有待定技術條件，不自行解除前置。
- 引用：README／PROJECT 現行證據引用改指向附錄；舊 WORK_LOG 與 W0 基線的歷史章節記錄不回寫，原 §5.1／§5.2／§5.4 留證據索引，§6.3.1 留設計結論與研究入口。
- 文件驗證：透過 read 分段取回完整文件、以一次性 Eval 檢查，24 個錨點唯一，27 個內部連結與 11 個跨文件連結均有目標；10 段歷史證據正文完整保留（僅 W3 子標題降階）、17 個 osu 固定版本引用及 14 條驗收旅程不變；2 組程式碼圍欄配對、25 個表格欄數一致。
- 邊界：僅修改規劃／引用／工作記錄，沒有產品程式、依賴、永久測試或新增文件；未建置、啟動 App／播放器、呼叫真實站點或執行整體驗收。

## 2026-10-10 — 完善規劃 §5.2 跨模塊功能串接

- 文件：將 W7 細分為搜尋直達、作品／播放／收藏、下載恢復、日常聚合、偏好／號池／快取保護及入口證據收口六個子包，補齊依賴、交接成果與實施順序；未重開既有交付或新增產品功能。
- 契約：補充查詢取消、穩定身份、原選擇／帳號恢復、持久資料清理、日常更新及能力錯誤邊界；現行組裝依 §2，不將 A.7 的歷史 owner 名稱當成新接線規範。
- 關卡：保留 M2 原六項門檻，新增 M1／W2 與 M2 證據採認／未簽收對照；有效帳號下載及使用中帳號人工驗收保持阻擋，不以 guest 或 fixture 替代，不擴充 Bilibili／Douyu 下載，不自行授權 UI 開工。
- 文件驗證：核對 §3、§4.6／4.7、A.7 及現有測試入口；一次性 Eval 檢查通過：4 個子節、6 個 W7 子包、原 M2 六項完整保留、3 張表格欄數一致，單元命令與既有 runner 相符，A.7 錨點存在。README／PROJECT 的範圍與狀態未變，無須同步改寫。
- 邊界：僅修改 FRONTEND_REFACTOR_PLAN.md 與本記錄；未改程式、依賴或測試，未執行編譯／單元／App／播放器／真實站點／傳輸驗收。驗證時序仍依 §0.2，文檔檢查不代表 M1／M2 通過。

## 2026-10-10 — 完成 W7.1／W7.2 缺口修補與單元交接

- W7.1：`BrowseSearchService` 對 Bangumi subject ID／來源 `SourceItemRef` 去重，保留順序及遠端游標；Bangumi 分頁錯誤現在攜帶先前結果，不丟結果、不把失敗隱藏成成功或空列表。URL 直達、來源能力篩選及每畫面取消 owner 沿用既有入口。
- W7.2：`BiliVideo.getVideoList`／`videoCatalog` 共用回應中的 BV 與指定分 P，API 播放準備直接消費同一所選節點；保留 av 別名與合集單集，移除缺分 P 後選第一項的行為。HTML 依分 P 身份而非陣列位置選擇，拒絕錯分 P／缺分 P 回應並保留單集影片標題。`VideoDecoder` 以 `BilibiliUrl.episodeIndex` 區分明確 ep 與無指定集數的 ss，不將缺失 ep 改播首集；直播別名／房間選擇路徑未改動。
- 既有契約核對：元資料依關聯 revision 提交；Work／Episode／來源映射仍由 WorkLibrary 保存；收藏只引用既有 Work 或普通影片連結，不新增 schema、不強造 Work、不新增 UI。播放原品質／線路驗證與來源／帳號 pinning 保留。
- 回歸：新增 `PlaybackSelectionRegression`，擴充搜尋行為回歸；W7 runner 一併執行 BangumiWorkSync／FavoriteLibrary。修正前舊 dylib 實際失敗於「first page must deduplicate stable identities」及「HTML returned first-part media for an explicit second-part request」；修正後 W7 六組、dependency --unit 四組及 WorkLibrary／舊模型遷移 runner 通過。
- 編譯／執行：Debug arm64 `xcodebuild` 通過，日誌 `.build/w7-build.log`；原有非本次改動的編譯警告未擴大清理。一次性離線解析程式載入本次 dylib，以本地 JSON 目錄輸入輸出 BV／av 均為 `part=2 cid=202 row=0`，缺分 P 為 `requested selection unavailable; no replacement`；不是遠端播放驗收。臨時程式與二進位清除。
- 文件／邊界：同步 FRONTEND_REFACTOR_PLAN §5.2.1 及 README 單元入口；PROJECT 產品範圍不變。未啟動 App／播放器、沒有真實站點／下載／傳輸驗收；不推定全站選集、全播放器或 macOS 13.5 通過，不解除 W2／M2 未簽收項，也未開始 W7.3–W7.6 新工作或 W8／W9。

## 2026-10-10 — 完成 W7.3–W7.5 缺口修補與離線交接

- W7.3：沿用既有 DownloadService／DownloadSourceResolver，沒有重造下載鏈。新增 DownloadServiceStateRegression，以隔離任務檔、偏好、帳號與可取消解析器執行真實服務狀態轉移；覆蓋精確集數／線路／品質／帳號恢復、活動記錄重讀為 paused／needsRecovery、進度保留與過期速率／ETA 清除，以及完成檔取址／刪檔／保留記錄。完成檔 URL 驗證不是播放器驗收。
- W7.4：DiscoveryService 的當季推薦現在檢查 YYYY-MM-DD 日曆往返一致性，排除 `2026-10-00` 等不存在日期，避免錯誤候選先佔相同來源項目。DiscoveryRegression 保留並補足排期去重、首次基線、重排／重現不報新、持久重讀、跨日本地星期、局部來源故障、明確待確認關聯及取消不提交；推薦理由由運行輸出觀察，不綁定文案測試。
- W7.5：下載狀態回歸確認新任務使用新目錄／暫存／併發快照，舊恢復任務保留原策略；暫停／恢復阻擋使用中帳號移除，取消釋放 lease，原帳號失效或移除均回報 authorization 且不呼叫解析器，guest 不採預設帳號。ImageCacheService 清理／淘汰前驗證可重建根與已知下載目錄的重疊，解析 symlink 別名後以路徑元件比較；拒絕時兩個快取根均不先刪除，保留下載 bytes。
- 修正前／後證據：舊 Discovery dylib 在無效日期候選斷言失敗；舊快取實作在巢狀下載目錄保護斷言失敗（檔案已遭淘汰）。本次修正後相應回歸通過。新增 runner 不啟動 App、播放器、HTTP listener 或下載傳輸。
- 實際驗證：Debug arm64 xcodebuild 通過，日誌 `.build/w7.3-7.5-build.log`；`bash Tests/run-w7-usecases.sh` 八組服务單元加快取檔案系統回歸全部通過；`bash Tests/run-dependency-regression.sh --unit` 四組通過。未執行真實 HTTP／HLS／Torrent 傳輸或有效網站帳號登入。
- 離線煙霧：一次性快取程式輸出 `cache=0, temporary=16, completed=16`，重疊清理拒絕且完成檔仍為 16 bytes；一次性 Discovery 程式載入本次 dylib，注入無效 subject 1 與有效 subject 2，實際輸出排期 `[2]`、推薦 `[2]`、`confirmation required: true` 及兩項推薦理由。臨時原碼／二進位／資料均清除，不視為頁面或遠端驗收。
- 文件／限制：同步 FRONTEND_REFACTOR_PLAN §5.2.1 及 README；PROJECT 範圍未變。W7.3–W7.5 交付限本次服務修補、單元與必要編譯，不解除 W2 真實雙帳號／重新授權及 M2 有效網站帳號下載／使用中移除門檻；W7.6 整體收口、W8／W9、新網站與 Torrent 擴充未納入。


## 2026-10-10 — 完成 W7.6 入口收口與單元交接

- 核對：主視窗 URL、書籤、Bilibili 動態、選集、HTTP、開啟檔案、JSPlayer 及播放器／彈幕沿用 AppServices 注入的解析與既有服務。補齊 FRONTEND_REFACTOR_PLAN §5.2.5 現行入口／owner／能力交接；區分畫面自有搜尋取消與 App 級播放／下載／持久狀態。Info.plist 未註冊入向 App URL scheme／文件關聯，不新增不存在的遷移範圍。
- 修補：OpenFilesViewController 的 action 呼叫可等待 openFiles；播放器開啟由 try? 改為 try，只有成功返回才通知 loadDanmaku 並關窗。解析／彈幕準備錯誤透過 presentError 回報，無串流明確 notFountData，取消不顯示錯誤，失敗保留原輸入；移除該入口原始錯誤日誌，避免遠端 URL 外洩。沒有新播放服務、來源或資料模型。
- 修正前／後：新增 OpenFilesEntryRegression，覆蓋解析失敗、彈幕局部失敗、空媒體及取消的錯誤可見性／輸入保留／停止後續完成路徑。修正前實際失敗於 opening failure must reach the caller instead of silently returning；修正後通過。測試只替換資料準備及呈現端，不啟動 App／播放器。
- 驗證：Debug arm64 未簽署 xcodebuild 通過；Tests/run-w7-usecases.sh 九組入口／服務单元及快取回歸、Tests/run-dependency-regression.sh --unit 四組、Tests/run-work-library.sh 遷移／身份／重讀均通過。日誌 .build/w7.6-build.log、w7.6-unit.log、w7.6-dependency.log、w7.6-work-library.log；失敗前記錄 .build/w7.6-before-unit.log。既有 JSPlayer @preconcurrency／AppIntents metadata 警告未擴大清理。
- 離線煙霧：一次性程式載入本次 dylib，真實 getVideo／openFiles 對 invalid 回報 invalidVideoUrl、保留输入且未載入視窗；獨立 VideoInspectionSession 返回精確 file URL／guest，前一 session stop 不影響該次解析。輸出 .build/w7.6-smoke.log；臨時原碼、二進位及隔離 home 已移除。
- 交接／限制：成功、取消、局部失敗及重開逐項對照記於 A.7.1，同步 README／PROJECT。本輪是單元、必要編譯與離線直接調用，不是 App 重啟、真實播放器啟動失敗提示、彈幕通知、多視窗、HTTP 斷線或真實傳輸驗收；不取代 A.7 歷史實播。W2 真實雙帳號／重新授權、M2 有效網站帳號下載／使用中移除仍未簽收，清單無網站帳號提供者的前置未改；W8／W9 與 Torrent 產品入口未開始。

## 2026-10-10 — 完成 W8.1 工作區與組件實作

- 範圍：依使用者「完成 W8.1」交付版本化 Layout、穩定組件／實例身份、七種真實服務組件、原生 grid／stack／split／group／tabs、寬度斷點、預設收藏雙欄及短期狀態。新增工作區固定選單與不可被自訂 Layout 移除的搜尋／開啟／設定／任務／恢復入口；沒有重造業務 owner 或全面替換舊主視窗。
- 保存與交易：嚴格驗證未知欄位、版本、身份、參數、尺寸、頁／節點／深度／文件限制；初次原子保存 UUID，壞檔不覆寫、明確恢復前備份。移動保留 owner、複製新身份且私有狀態獨立、移除只撤銷本實例訂閱；跨斷點缺目的頁拒絕整筆交易。
- 能力：排期／收藏更新／推薦可獨立停用，停止對應 loader 且保留更新基線；DownloadService actor 保護活動任務／入場／metadata import／worker 清理與偏好保存，停用後禁止新建／恢復但任務入口保留。核心及無法確認外部播放器生命週期的彈幕功能顯示不可停用原因。移除 discovery 面板不取消共用刷新。
- 實際驗證：Debug arm64 未簽署 xcodebuild 成功；WorkspaceLayoutRegression、W7 九組入口／服務回歸與快取回歸、dependency --unit 四組通過。日誌 `.build/w8.1-build.log`、`w8.1-layout-unit.log`、`w8.1-service-unit.log`、`w8.1-dependency-unit.log`。
- 原生煙霧：一次性 NSApplication host 載入本次 dylib，不建立正式 AppDelegate；隔離記憶體 Core Data 各 80 筆作品／連結收藏、離線搜尋 loader 與不傳輸的真實下載服務。驗證 960×640 兩欄各 479.5×567、查詢／排序／選取／捲動、split 調整保存重開、move/copy/remove owner、共享收藏變更、移除自訂頁後固定搜尋／任務、取消下載及移除面板不停止任務；1280×800 巢狀 grid/group/stacks/tabs 與斷點保留頁籤通過。輸出 `PASS COMPLETE native workspace smoke`，日誌 `.build/w8.1-native-smoke.log`，bitmap `.build/w8.1-evidence/workspace-960.png`／`workspace-nested-1280.png`。
- 修正前／後：原生首次實跑在尚無共同父 view 時啟用寬度 constraint 而崩潰；修正加入順序後再抓到 split 子 view 被 Auto Layout 壓成最小高度。修正 frame owner 與 group／stack 跨軸約束後，真實 smoke 全部通過，巢狀畫面填滿容器；連結輸入欄位不再壓成零寬。
- 文件與限制：README、PROJECT、FRONTEND_REFACTOR_PLAN §5.3.1 同步；臨時 host／runner／格式配置與隔離資料清除，保留日誌／bitmap。bitmap 部分原生按鈕／頁籤文字未完整顯示，不宣稱完整外觀驗收。未啟動正式 App、遠端站點、播放器或真實 HTTP／HLS／Torrent 傳輸；macOS 13.5／Intel 實機未驗證。W2／M2 缺口保留，W8.2–W8.4、W9／W10 與 W11.4 不在本次交付。


## 2026-10-11 — 完成 W8.2 Skin 包與資源

- 範圍：交付 Skin v1 manifest／theme／components、語義槽與狀態、明暗變體、個人覆寫、PNG／JPEG／TTF／OTF 驗證、共用縮圖快取與原生呈現。沿用 W8.1 工作區與服務 owner，不重建 query、不變更功能偏好、不重發播放／下載；固定「工作區 → 外觀」不受 Skin／Layout 控制。
- 管理：提供 .iinaskin 匯入／選擇、明暗模式、字級／密度、原包與個人衍生包匯出、獨立作者佈局套用、移除及恢復內建。安裝採不可變內容修訂與原子 catalog；同 ID 變更須確認檔案差異，候選外觀先驗證，啟用失敗保留原修訂／選擇。衍生包保留授權／來源並用新 ID，允許清單匯出不帶 session／帳號／收藏／任務資料。
- 安全：Stored／Deflate ZIP 實際輸出、CRC、正規化路徑／重名、連結、加密、巢狀包、型別及資源量檢查；腳本及可執行素材拒絕。上限 ZIP 65 MiB、256 項、單檔 16 MiB、展開 64 MiB、JSON 1 MiB、圖片每邊 8192／64,000,000 像素、圖片快取 48 MiB；字體限定 process scope，準備／啟用 owner 共用引用計數。
- 修正前／後：實際 ZIP 重匯入暴露 macOS /var 與 /private/var 根／子路徑正規化不一致，修正一致化相對路徑。乾淨 profile 衍生包 smoke 原先在 visual equivalence 斷言失敗；將即時解析及衍生匯出共用同一 cascade，保留永久的組件狀態字級與圖片組 fallback 行為回歸，修正後通過。
- 實際驗證：Debug arm64 未簽署 xcodebuild 成功；SkinAppearanceRegression、SkinPackageStoreRegression、WorkspaceLayoutRegression、W7 usecases 及 dependency --unit 通過。覆蓋最大合法 64 MiB／256 項包及加一越界、安全 ZIP 拒絕、替換回滾、損壞 catalog 恢復、選擇重讀／移除與乾淨 profile 匯出重匯入；真實 PNG 在 8192 邊長及 64,000,000 像素可呈現、越界拒絕。一次性真實 TTF 在 16 MiB 可註冊／切換修訂，16 MiB+1 拒絕。
- 隔離煙霧：原生 AppKit host 實際繪製背景／placeholder／進度，原生 action 僅一次，selected／pressed／disabled、淺深色／個人覆寫／恢復內建通過且輸入保留。包 smoke 通過真實 ZIP 安裝／去重／替換確認／啟用失敗回滾／重新建立 store／移除，作者 Layout bytes 不變。沒有正式 AppDelegate、遠端請求、播放器或真實傳輸。
- 證據：`.build/w8.2-build.log`、`w8.2-appearance-unit.log`、`w8.2-package-unit.log`、`w8.2-layout-unit.log`、`w8.2-service-unit.log`、`w8.2-dependency-unit.log`、`w8.2-native-smoke.log`、`w8.2-package-smoke.log`、`w8.2-font-smoke.log`；bitmap `.build/w8.2-evidence/native-skin-dark.png` 已檢視。臨時原碼／二進位／格式配置與資料清除，保留日誌／bitmap。
- 文件與限制：README、PROJECT、FRONTEND_REFACTOR_PLAN §5.3.2 同步。完整 Skin 管理／預覽／編輯體驗仍為 W8.4，W8.3 腳本未開放；W9／W10／W11.4 不在此次範圍。未重驗正式 App 端到端、macOS 13.5／Intel 實機、網站／播放器／傳輸，不解除 W2／M2 缺口。

## 2026-10-11 — W8.3 本機實作與驗證，正式安全關卡保留

- 範圍：實作真正 JavaScript `buildLayout(context)` 的獨立 JavaScriptCore helper、父程序 runner、嚴格 Layout 解碼／驗證、原生差異檢閱／隔離預覽、確認保存與整筆 undo／redo。context 僅含契約版本、組件描述及作者明確 JSON 配置，不包含 session、帳號、收藏或任務資料。安裝、啟動與縮放不執行作者碼。
- 隔離：helper 在讀取 source 前安裝 deny-default Seatbelt、關閉繼承 FD、core dump 與 JIT，不提供原生橋接。source 128 KiB、stdin 256 KiB、stdout 實際 UTF-8 1 MiB、父程序 stderr 8 KiB；父子 2 秒 deadline，父程序取消／失敗 SIGKILL 並回收。128 MiB physical footprint 為約 5 ms 取樣終止閾值，允許瞬間超量，不宣稱 allocator hard cap。
- 安全實跑：hardened-runtime ad-hoc 簽署 helper 的真正 JS、無限迴圈／序列化 getter 超時、記憶體成長先於 deadline 終止、行號錯誤、ASCII／多位元 UTF-8 精確輸出邊界及 source／stdin 越界通過。相同 sandbox 原生探針有未受限成功控制，檔案讀寫、localhost connect、fork／exec 確認權限拒絕；Keychain Mach lookup 確認 BOOTSTRAP_NOT_PRIVILEGED。探針只存在測試編譯，不用 JS globals 缺席冒充 OS 安全證明。
- 保存／原生實跑：同一 validator／store 保存重讀，錯誤及取消後原檔不變；隔離 AppKit host 透過包內 helper 產生雙收藏候選，驗證 1280px 並排／1000px 堆疊、取消、stale baseline 拒絕、明確套用／持久化、單筆具名 undo 無殘留 action、redo／再次 undo。預覽使用真實 renderer／原生面板，但不讀業務服務、不寫 session；以 screencapture 檢視實際視窗，安全提示及套用／取消文字可讀。
- 工程／回歸：最後一次未簽署 Debug xcodebuild 成功，App 包內 universal helper 的 arm64 與 Rosetta x86_64 slice 均實際執行 JS 迴圈產生兩頁 JSON。WorkspaceLayoutScript、WorkspaceLayout、SkinAppearance、SkinPackageStore、W7 usecases 與 dependency --unit 通過；沒有啟動正式 AppDelegate、遠端網站、播放器或真實傳輸。
- 證據：`.build/w8.3-security.log`、`w8.3-script-unit.log`、`w8.3-layout-unit.log`、`w8.3-appearance-unit.log`、`w8.3-package-unit.log`、`w8.3-service-unit.log`、`w8.3-dependency-unit.log`、`w8.3-build.log`、`w8.3-packaged-helper-smoke.log`、`w8.3-rosetta-smoke.log`、`w8.3-native-smoke.log`；實際視窗 `.build/w8.3-native-window-wide.png`／`w8.3-native-window-narrow.png`。一次性原碼／執行檔／格式配置／隔離資料清除；README、PROJECT 與重構文檔 §5.3.3 同步。
- 必要阻塞：缺 macOS 13.5 最低系統與本 fork 正式簽署／App Sandbox 發佈組合實测。deployment target、Rosetta 與 ad-hoc hardened 簽署不能代替該證據；`externalImportEnabled` 保持 false，Skin ZIP 繼續拒絕 `.js`。外部選檔入口未做正式 App 端到端驗收，不宣稱 W8.3 全項完成，不解除 M2／M3，W8.4／W9／W10／W11.4 不在本次範圍。

## 2026-10-11 — 完成 W8.4 編輯、預覽與分享

- 原生編輯：工具列「編輯佈局」提供組件／容器樹、滑鼠拖放與鍵盤移動、尺寸網格／split 比例、頁面新增／命名／排序／隱藏／首頁及斷點版本。沿用 W8.1 renderer／Registry／validator，不新增業務服務 owner；草稿 undo／redo 與已保存工作區分離，取消不寫檔，確認一次提交，過期 baseline 拒絕覆蓋。整份提交仍可 undo／redo，刪除組件的 session 狀態保留供撤銷。
- Skin 管理：固定「工作區 → 外觀 → Skin 管理…」提供清單、匯入／拖入／`.iinaskin` 開啟、套用、移除、恢復內建、原包／衍生包匯出及作者目錄重載。外部資料先複製成驗證快照再進入隔離原生預覽；取消不安裝，同 ID 不同內容必須明確同意替換。預設只套外觀，明確勾選才覆蓋作者 Layout；套用檢查外觀及佈局 baseline，catalog 先提交，失敗回滾，回滾失敗保留兩份修訂並回報複合錯誤。
- 格式／範例：新增可選 `homePageID`、`hiddenPageIDs`、`collapsedInstanceIDs`，不改既有 v1 必填契約。Layout 分享清除各頁與斷點的組件參數；個人外觀覆寫只進衍生包，新 ID／來源資訊保留。`Examples/Skins` 提供最小與完整作者目錄、26 張原創 CC0 PNG、19 個槽 × 8 種狀態、7 個組件覆寫、明暗變體、生成／打包工具及格式文件。兩例通過真實匯入／去重／原包匯出／乾淨 profile 重匯入；衍生包的新 ID、來源及斷點參數清除已驗證。
- 回歸／建置：未簽署 Debug arm64 xcodebuild 成功；dependency --unit、SkinAppearance、SkinPackageStore、WorkspaceLayoutScript、WorkspaceLayout 與 W7 usecases 通過。包回歸涵蓋預覽快照不可變、作者重載、同 ID 替換、套用／回滾失敗、重新開啟及分享資料邊界。
- 原生實跑：一次性 AppKit host 使用記憶體 Core Data 與正式 Debug dylib，不啟動正式 AppDelegate。1280×800／960×640 預覽及編輯視窗已截圖檢視；完整 Skin 的長作者／授權 metadata 原先撐大最低視窗，修正壓縮及截斷後實測 960 寬。實際按鈕操作證明匯入取消不安裝、最小／完整 Skin 套用不改 Layout bytes、選擇重讀、明確作者 Layout 提交、管理器重開、恢復 Skin 不重排頁面。實際滑鼠跨頁拖放、單次草稿 undo／redo、取消保存不變、鍵盤跨頁移動、保存重讀及整筆 undo／redo 均通過；預覽業務命令計數為零。
- 證據：`.build/w8.4-build.log`、`w8.4-dependency-unit.log`、`w8.4-appearance-unit.log`、`w8.4-package-unit.log`、`w8.4-script-unit.log`、`w8.4-layout-unit.log`、`w8.4-service-unit.log`、`w8.4-examples.log`、`w8.4-native-smoke.log`；實際視窗 `w8.4-full-preview-narrow.png`、`w8.4-editor-narrow.png`、`w8.4-skin-manager.png`、`w8.4-drag-redo.png`。README、PROJECT、重構計劃 §5.3.4 與範例文件同步。
- 快捷鍵修正：隔離原生事件重現 Cmd+Option+↑ 未處理；將可見箭頭字元改為 AppKit 方向功能鍵字元。相同事件修正後確實移動選取組件，撤銷後仍可完成跨頁編輯與保存，前後證據保留於 `w8.4-keyboard-before.log` 與最終 native smoke 日誌。
- 清理：一次性原生 host 原碼、執行腳本、隔離 profile／執行檔與空白暫存目錄已移除；保留回歸日誌、原生截圖及可重新生成的範例包。
- 限制：未把檔案關聯的編譯結果宣稱為 Finder → 正式 App 的端到端驗收；未重驗完整 VoiceOver 旅程、macOS 13.5／Intel 實機、正式簽署／App Sandbox 發佈組合、遠端網站、播放器或真實傳輸。W8.3 `externalImportEnabled` 仍為 false；不解除 W2／M2／M3 缺口，不宣稱 W9／W10／W11.4 完成。

## 2026-10-11 — 完成 W9 頁面與 W11.4 UI 整合

- 頁面：預設 184 pt 側欄、常駐全域搜尋與返回；發現分區狀態／日期／來源證據、分類與來源搜尋／分頁／取消、作品／影片 typed 詳情、雙欄收藏編輯、下載命令、五組設定及 Torrent 匯入。新增 detail.media、settings.preferences、torrent.import 三種可編排組件，沿用 Layout v1／Skin／既有服務，不另建任務或資料 owner。
- 精確命令：詳情共用來源／集數／分 P／品質／線路／帳號選擇，手動 Bangumi／来源關聯及集數映射；JSPlayer／彈幕固定操作上下文，播放視窗由 AppServices 持有。收藏可改作品名稱／別名及失效連結名稱，移除不刪底層資料；下載沿用暫停／恢復／取消、開啟／Finder／記錄及檔案刪除命令。
- 設定／Torrent：搜尋結果直接聚焦設定控制項，非同步帳號刷新保留焦點；偏好／來源／帳號／快取及 Skin／Layout 都連接正式命令。Torrent metadata 前先同意 P2P 與有效上限，精確選檔後分別啟動 reader／下載；活動上限尊重較低既有限制，停止只等待 Torrent admission，不阻塞於無關 HTTP 任務。舊 WindowManger 與四個 SwiftUI 設定頁移除，共用登入及外掛安裝保留；W10 舊主視窗未擅自全面切換。
- 實跑修正：詳情初始捲動置頂；設定非同步刷新不搶焦點；原生控制項 appearance 跟隨 Skin 明暗，修正淺色背景／深色文字樣式混用；本組件密度不影響另一欄或共享 Skin。恢復頁返回不丟失原搜尋／分頁 owner。
- 驗證：未簽署 arm64 Debug xcodebuild 成功，Info.plist／pbxproj lint 通過；WorkspaceLayout、WorkLibrary、WorkspaceSettingsSearch、W7 usecases、dependency --unit、SkinAppearance 通過。新增回歸覆蓋失效 URL 只改名稱、作品改名／別名保存並保留關聯、來源移除隔離、Torrent 限速邊界與停止非 Torrent 隔離。
- 原生證據：一次性 host 以正式 Debug dylib、記憶體 Core Data／隔離 profile／離線載入器及真實 AppKit event loop 執行；搜尋分頁 → typed 詳情 → 返回保留、雙欄密度隔離、DownloadService 實際暫停／取消、設定聚焦／Preferences 重讀、三種新產品頁的隔離預覽均通過。1280×800／960×640、明暗視圖已擷取檢視。最初 async-main host 未建立完整事件迴圈，預覽等待時提前結束；改用 NSApplication.run 後取得明確 PASS，不把提前退出計為通過。
- 證據檔：`.build/w9-build.log`、`w9-layout-unit.log`、`w9-work-library.log`、`w9-settings-unit.log`、`w9-service-unit.log`、`w9-dependency-unit.log`、`w9-skin-unit.log`、`w9-native-smoke.log` 及 `w9-*.png`。README、PROJECT、計劃 §5.3.5／W11.4 與 Skin 作者契約同步；一次性 host／debug fixture 已移除，保留日誌與視圖證據。
- 限制：WindowServer screencapture 回報無法建立影像，證據為實際 NSView bitmap，未宣稱系統材質／正式視窗合成驗收。未啟動正式 AppDelegate、遠端網站、播放器或 P2P；Finder 關聯、完整 VoiceOver、macOS 13.5／Intel、正式簽署／公證及 §8 集中旅程仍待驗收。W8.3 外部脚本入口關閉；W2／M2／M3／MT3 與 W10 不因本次實作交付而通過。

## 2026-10-11 — W10 主入口切換與舊 UI 清理交付，總驗收仍受阻

- 入口：以明確的 AppDelegate.main 啟動 NSApplication／持有 delegate，Workspace 成為唯一主視窗；Dock 重開喚回同一 owner。MainMenu 程式化提供原生編輯／視窗與固定 Workspace 命令，移除無對應文件模型的舊選單及全域 Core Data undo 分派。⌘O 影片＋XML／B 站 ID、Skin／Torrent 檔案、JSPlayer、登入容器與外掛安裝保留。
- 舊 UI 清理：移除 Main／Preferences storyboard、舊主視窗／側欄／選集／AppKit 設定、只屬舊 UI 的 formatter／通知／localization 及 Xcode 引用。JSPlayer row 遷入播放器目錄，LivePlayer 遷至 Preferences，五個仍使用的外掛文案遷入 Localizable。刪除 Sparkle、Settings、SDWebImageSwiftUI 無剩餘 caller 的依賴與鎖檔項；模型、Web 資源、播放器及授權保留。build log 證明舊 compiled storyboard／nib／strings／framework 亦從產物清除。
- 能力補齊：discovery.followed 使用原 BilibiliDynamicManger，保留刷新／新舊分頁／選集入口，增加明確失敗及弱 delegate／取消；舊作者 Layout 可經固定入口恢復頁到達。直播收藏保留狀態／網站篩選、原色彩、刷新與手動拖曳；過濾時禁止拖曳。面板持有刷新工作並於 detach 取消，DataManager 不再自行建立無 owner Task，刪除其已無 caller 的舊 bookmark CRUD 包裝。詳情保留 Option 抑制自動開啟、精確選擇、外部／JSPlayer 及 Huya 預熱，外掛門檻不阻擋 normal IINA／mpv／停用彈幕。設定補回狀態色與瀏覽器彈幕測試。
- 發佈安全：移除 Sparkle 啟動／更新命令及上游 feed／公鑰、舊 0.7 公告；不改 Bundle ID、真實資料／憑證或持久偏好。這不是正式 fork 發佈配置。
- 建置／單元：macOS 27.0.1 arm64、Xcode 27.0；最終未簽署 Debug BUILD SUCCEEDED，plist／pbxproj lint、dependency --unit、W7 usecases、W5 收藏及 Bookmark v0.3／Library v0.4 備份／遷移／冷重開／還原與 WorkspaceLayout 回歸通過。遷移 failed-save 情境故意觸發 Core Data optimistic-lock／rollback 日誌，最終 PASS；不是忽略測試失敗。
- 原生煙霧：正式 Debug dylib 加隔離 home／Bundle ID、停用遠端來源，未執行正式 AppDelegate 啟動。真實 AppKit 控制項驗證取消刷新不改原狀態、過濾時拒絕 reorder／清除後恢復、live 篩選得到正確持久 UUID 對應列、關注動態初始／新／歷史順序與帳號失效呈現／detach 拒絕更新、顏色保存、設定恢復頁不覆寫作者 Layout、⌘O 真正 storyboard 的影片／XML 控制項、關窗重開只保留一個 Workspace、拒絕未支援檔案及 magnet 路由。1280×800／960×640 NSView bitmap 已檢視；修復固定工具列深色模式白色空按鈕後再次通過。系統仍記錄 sandbox_extension_issue_file_to_process 警告，所有指定煙霧斷言完成；不冒充 WindowServer 合成或正式簽署驗收。
- 證據：`.build/w10-build.log`、`w10-final-build.log`、`w10-dependency-unit.log`、`w10-usecases-unit.log`、`w10-favorites-migration.log`、`w10-layout-unit.log`、`w10-native-smoke.log`；`w10-favorites-wide.png`、`w10-followed-preview.png`、`w10-settings-wide.png`、`w10-settings-narrow.png`、`w10-open-files.png`、`w10-reopened-workspace.png`、`w10-torrent-route.png`。一次性 host／launcher 與隔離資料清除；README、PROJECT、AGENT、計劃 §5.3.6 與 Skin 作者組件表同步。
- 未簽收：既有暫停政策下，未驗正式 App 冷啟動／Finder、遠端逐站／真實帳號／播放器／HTTP／P2P、完整鍵盤／VoiceOver、1000 收藏容量／延遲；缺 macOS 13.5／Intel 實機及 fork Developer ID／公證／資料共存決策，本機 Apple Development identity 不是發佈證據。W2／M2／M3／MT3 與 W8.3 安全門檻仍保留，外部腳本匯入仍 false。W10 切換實作交付不等於 W10／M4 全部驗收完成。

## 2026-10-11 — 目前推薦來源切換為 Bangumi 日曆與動畫趨勢

- 依使用者提供的 `https://bangumi.tv/calendar` 與 `https://bangumi.tv/anime/browser/?sort=trends`：今日放送沿用官方 calendar API，推薦直接解析指定動畫趨勢第一頁，保留網站順序並按 subject ID 去重。公開 API 的 browse `date`／`rank` 及 search `heat` 不等價於網站 trends，因此不以其他排序代替。
- `BangumiService.trendingSubjects` 沿用現有 SwiftSoup、HTTP、身分快取與取消模式，新增標題／原名／HTML entity／封面解析；保留 24 小時快取、強制刷新、過期資料及明確失敗。公開頁請求清除帳號 HTTP context，不攜帶 Cookie／OAuth；驗證頁、無有效目錄及不安全 subject 連結不能污染已保存推薦。無新增依賴。
- `DiscoveryService` 刪除當季搜尋及播放站點同名匹配流程／注入參數；推薦只持有 Bangumi subject 及理由，無日期或播放來源可用性門檻。日曆／趨勢局部失敗互不抹去，過期快取錯誤傳至 UI。收藏來源更新基線不變。Workspace 卡片標示來源並開啟 Bangumi 作品詳情，不把 Bangumi subject URL 交給播放解析器；推薦能力僅依賴 metadata，組件 ID／Layout 格式不變。
- 驗證：三個公開 URL（日曆頁、趨勢頁、calendar API）皆取得 HTTP 200；捕獲回應經實際 Debug 模組服務解析，24 筆趨勢順序、雙語標題／entity／封面及七天排期斷言通過。最終未簽署 Debug BUILD SUCCEEDED；`Tests/run-w4-bangumi.sh`、`Tests/run-w7-usecases.sh`、`Tests/run-workspace-layout.sh` 全部通過。新增／調整的永久回歸涵蓋排序／去重、非當季與無日期作品、停用所有播放來源、分區失敗、過期資料、身分快取、強制刷新、驗證頁、取消及憑證隔離。
- 原生煙霧：隔離 home／Bundle 資源、記憶體資料庫及真實控制器，檢查今日排期與趨勢列順序、雙擊導向 subject 詳情 callback、空結果／失敗／舊快取呈現；實際 NSView bitmap 已檢視。未啟動正式 AppDelegate、真正作品詳情／瀏覽器、播放器或傳輸；保留既有整體驗收暫停與 W10／M4 未簽收狀態。系統 sandbox_extension 警告仍存在，煙霧斷言均完成；不將 bitmap 視為正式 WindowServer／簽署驗收。
- 證據：`.build/bangumi-discovery-build.log`、`bangumi-service-regression.log`、`bangumi-discovery-regression.log`、`bangumi-layout-regression.log`、`bangumi-discovery-native-smoke.log`、`bangumi-discovery-panels.png` 及捕獲頁面／JSON。README、PROJECT、計劃 §4.7 與本記錄同步；一次性煙霧 host／launcher 及隔離資料清除，保留可重現解析的捕獲回應與日誌。

## 2026-10-11 — 每日放送改用 Bangumi 作品簡介頁頭圖

- 依使用者要求，`BangumiService.subjectCover` 請求 `https://bangumi.tv/subject/<id>`，在 `#bangumiInfo .infobox` 優先擷取主封面原圖連結、其次主封面 img；限制 Bangumi 圖床並轉 HTTPS，忽略頁面其他圖片／頭像與日曆 API 圖片。公開匿名請求、按 subject ID 的 24 小時快取、強制刷新、舊圖＋失敗與取消沿用既有服務模式。
- `DiscoveryTodayBroadcast` 分開持有簡介頁頭圖 URL；每日放送僅解析當日去重作品，工作群組最多四個並行且結果維持排期順序。個別頁面失敗保留排期，無舊圖時顯示無封面與分區錯誤；不改趨勢推薦、作品詳情或其他卡片的圖片來源。
- 驗證：實際 `subject/390200` 簡介 HTML 與原圖皆 HTTP 200；捕獲資料經正式 Debug 模組解析／快取，隔離原生面板成功顯示實際圖片，確認未用錯誤的 API 圖片且雙擊仍導向該 subject。未簽署 Debug BUILD SUCCEEDED；W4 Bangumi 與 W7 usecases 回歸通過，涵蓋原圖優先／縮圖備援、錯誤結構／圖床、快取刷新／失敗／取消，以及亂序完成、去重、僅當日載入和失敗保留排期。
- 證據：`.build/bangumi-cover-build.log`、`bangumi-cover-service-regression.log`、`bangumi-cover-discovery-regression.log`、`bangumi-cover-native-smoke.log`、`bangumi-subject-cover-panel.png` 及捕獲 HTML／JPEG。原生 host 以預載圖片快取避免聯網，已檢視 NSView bitmap；未啟動正式 AppDelegate／播放器，不擴大為端到端驗收。一次性 host／launcher 與隔離資料清除；README 與計劃 §4.7 同步。

## 2026-10-11 — 恢復正式 App 驗收並制定六項修復計劃

- 政策：依使用者要求解除整體／端到端驗收暫停，AGENT、README、PROJECT 與重構計劃現行規則同步；歷史未驗證記錄不改寫為通過。
- 規劃：FRONTEND_REFACTOR_PLAN.md §5.5 新增 R0–R7、依賴與正式 App 驗收矩陣，涵蓋搜尋失效、連點空白佔位、設定兩層導覽、固定詳情模板、番劇／非番劇隔離及番劇自動尋源／手選來源。§4.6、§6.2／§6.5 同步行為契約。
- 決策：番劇尋源／播放不顯示帳號選擇，公開來源 guest 且不暗用憑證；唯一可信作品／集數映射才自動播放，其餘選候選，授權限制明示，不新增站點或傳輸引擎。
- 驗證：正文錨點唯一、R0–R7 完整、程式碼區塊成對及 README／PROJECT 修復入口目標存在。閱讀既有搜尋／詳情／應用控制器作範圍依據；搜尋與空白缺陷依使用者回報成立，未聲稱根因已確認。
- 邊界：本輪只交付計劃與政策，未改 App 程式、未建置／啟動 App、未執行實播或端到端驗收。R0–R7 尚未實施，W2／M2／M3／MT3／M4 與 W8.3 安全門檻保留。

## 2026-10-11 — 完成 R0 正式 App 驗收基線

- 交付：本份來源 Debug BUILD SUCCEEDED，獨立驗收 Bundle ID `org.iina-ani.r0-baseline`；執行 `.build/xcode/Build/Products/Debug/IINA+.app/Contents/MacOS/IINA+`，正式 AppDelegate 冷啟動與實際 Workspace 視窗，不以隔離 host 代替。未改 App 原始碼、工程或測試。計劃 §5.5.0 記錄操作、定位狀態與限制，README／PROJECT 同步 R0 已完成、R1–R7 未驗收。
- 資料：CFFIXED_USER_HOME＋獨立偏好／HTTP storage／Keychain domain；App log／lsof 確認 Core Data、任務及快取在 `.build/r0/home`。原 profile 七個資料根的 380 檔驗收前後 SHA-256 完全相同，沒有複製／清除使用者帳號、Cookie 或收藏。原 IINA PID 76128 保留，沒有播放或 P2P。
- 正式操作：全域搜尋「葬送的芙莉蓮」Return → 面板 → 47 筆，記錄六站 HTTP 403／格式不符及僅顯示前三行錯誤；面板搜尋 Bangumi subject/390200 URL → 0 筆／VideoGetError error 8。1280×800、960×640 內容尺寸各同頁連點 20 次，搜尋／收藏交替 20 輪；每次 AXPress 回 0。截圖保留寬視窗右側／底部空白、窄視窗內容溢出；本次未觀察到空白隨點擊數持續增長，不否定使用者回報。⌘W → ⌘⇧1 正式關窗重開仍顯示原查詢／錯誤。
- 定位：renderer 佈局前 breakpoint 讀到 host 960×599、1 個 shell、service/product/container owners 5/0/1、history 41；搜尋 attached=true、generation=1、rows=47。這不是佈局後尺寸或無洩漏证明。除錯表達式曾對輔助 TUINSWindow 的 nil controller 強制 unwrap，已回滾並繼續操作；此 LLDB 錯誤不列作 App 自發 crash。
- 埠／結束：驗收前 19080／19280 空閒；`-dmPort 19280` 未生效，實際 listener 為 127.0.0.1:19080，沒有衝突。正式結束選單退出 exit 0，行程與 listener 已消失；原 IINA 保留。一次性操作／雜湊工具清除，隔離 profile 保留供對照。
- 證據：`.build/r0/evidence/` 的 build.log、app.log、open-files.txt、profile-verification.json、debugger.json、各操作 actions／AX 與 cold-launch／search-settled／bangumi-url-error／search-repeat20／narrow-repeat20／alternate20／reopened PNG；文件內列出主程式 build／SHA-256。沒有新增永久測試，R0 調查用正式執行證明。搜尋／導航修復及完整 R7 矩陣、實播／彈幕／下載、有效帳號、最低系統均未完成；M2／M3／MT3／M4 與 W8.3 門檻保留。

## 2026-10-11 — 完成 R1 搜尋修復及正式 App 驗收

- 修復：BrowseSearchService 新增三個 Bangumi host 的精確 subject URL 路由及 enabled＋search 能力選單 API；其他 URL 保留解碼器路径。WorkspaceServicePanelController 新增取消、空輸入／新查詢狀態清理、分頁載入／保留結果、generation／detach 晚回應隔離、按顯示分類決定錯誤與更多狀態、新查詢回列表頂部及完整六站錯誤。追蹤 renderer／AppServices factory／詳情 action，無需改工程、renderer、詳情或資料模型。
- 回歸：新增 URL host／scheme／path／ID 邊界、無分頁／元資料依賴、來源能力篩選、失敗分組在其他來源後續分頁中保留的消費者回歸；Debug BUILD SUCCEEDED，Tests/run-w7-usecases.sh 全部通過。
- 正式 App：org.iina-ani.r1-search，.build/r1/home；全域 Return 得 47 筆及完整六站局部錯誤，bilibili＋來源影片 20→40 筆，返回保留 query／分類／來源及 scrollbar 0.4→0.3999406。Cancel／晚回應、快速 keyword→subject URL 替換、成功空來源、空輸入與不支援 URL 錯誤均操作；subject/390200 打開真實精確詳情，bilibili-live 無 keyword search 仍可輸入 URL。
- 實播：普通 BV1xx411c7mD URL→詳情／分 P／清晰 480P→正式播放按鈕→真實 mpv 視窗，截圖觀察不同解碼畫面。使用 guest／隔離 mpv 偏好，enableDanmaku=NO；不把 JSPlayer 的既有能力拒絕或送出 seek 鍵算成通過。原 IINA 保留。App 正式退出 exit 0，owned mpv 另以 SIGTERM 結束，listener 已消失。
- 資料／證據：原七個 profile 根共 380 檔 SHA-256 完全相同；未複製／清除帳號、Cookie、收藏。證據 .build/r1/evidence/ 的 build-final.log、regression-final.log、smoke-checks.json、final-* AX／PNG、mpv-playing／mpv-osd／mpv-clock 及 profile-verification.json；計劃 §5.5.0.1 記錄完整對照及 Debug dylib SHA-256。一次性操作／smoke／雜湊工具清除，隔離 profile 與去敏證據保留。
- 限制：eacg／forest／kanba／youknow 仍 HTTP 403，fengche／hanime1 仍格式不符，未擴大站點修復宣稱。Bilibili 模糊搜尋可能對未知字串回合法命中，空狀態以 girigiri 真實空回應驗證。⌘W／⌘⇧1 保留 query／分類／來源，結果須重新提交；R2 空白／重開完整狀態、R3–R7、真實彈幕／播放器多視窗／重連、有效帳號、最低系統／Intel、M2／M3／MT3／M4 與 W8.3 未簽收。

## 2026-10-11 — 完成 R2 導航空白與關窗重開修復

- 修復：WorkspaceRenderer 以 renderedPageID／activePages 阻止同頁重建，跨頁先卸載舊 shell；scroll 填滿剩餘寬度、host 固定底邊、toolbar 垂直 stack hugging，移除右側／底部額外空白。Layout／預覽／capability 變更仍重繪。
- 狀態：關窗 detach 取消畫面查詢與訂閱但保留已完成結果／詳情／設定 owner；各面板 attach 冪等恢復。搜尋載入中關窗走既有 cancelSearch／generation，晚回應不能覆蓋；Layout 移除 instance 仍釋放 owner。Torrent 保留未提交匯入／儲存權限釋放語義，重開為新匯入畫面；已提交任務不停止。沒有改 App controller、SessionState、工程或資料模型。
- 驗證：Debug BUILD SUCCEEDED；Tests/run-workspace-layout.sh、Tests/run-w7-usecases.sh 全部通過。正式 AppDelegate／Workspace，org.iina-ani.r2-navigation；最終單實例 .build/r2/acceptance-home，原 IINA 保留，App 本身綁定 127.0.0.1:19080，正式結束選單退出 exit 0。早期迭代行程全部清除後重跑；不以按鍵派送或工具選擇回傳碼當成操作成功。
- 正式操作：1280×800／960×640 搜尋各連點 20 次，搜尋↔收藏 20 輪，其他四頁各 20 次；寬／窄外 scroll 分別 1096×759／776×599。分頁→返回→AXCloseButton 真正關窗（AX 無視窗）→固定選單重開保留最終 47 筆、來源影片／全部來源、錯誤與 scrollbar 0.4；補充 bilibili 40 筆／篩選／滾動亦保留。設定與真實 BV 影片標題／網址重開保留，搜尋載入中關窗後等待 6 秒仍已取消／0 列。
- 證據：.build/r2/evidence/ 的 build.log、layout-regression.log、search-regression.log、single-* AX／PNG／actions；完整對照在 FRONTEND_REFACTOR_PLAN.md §5.5.0.2，README／PROJECT 同步 R2 已完成。實作 dylib SHA-256 61909bccdcc071e25cbb6634a493254da6c8c01ec37a16dda3571fd08090c1c2。一次性 AX／截圖／狀態工具已移除，隔離 profile 與正式視窗證據保留；listener 已消失。
- 限制：原 profile 本輪未做前後雜湊，不沿用 R1 的 380 檔未變宣稱；未複製／清除私人帳號或收藏。未實播、彈幕、P2P、有效帳號、macOS 13.5／Intel 或 App 重啟持久化；同一行程關窗重開不代簽 R7。沒有加入原始碼／wiring 檢查型測試；UI 以正式 smoke 證明。R3–R7、M2／M3／MT3／M4 及 W8.3 門檻保留。

## 2026-10-11 — 完成 R3 類型隔離與正式 App 重啟驗收

- 資料：SourceSelection／SourceSearch／SourceConfiguration／原生適配器加入 MediaContentKind／MediaClassification 與出處，未知保持待確認，不按 host、標題或 Bangumi ID 猜測；Bilibili PGC 使用既有季 type。Work 保存分類與手動優先旗標，不更換 Work／Episode UUID 或 SourceItemRef 身份。
- 持久化：既有 BookmarkFavoritesMigration 檔承載 WorkClassificationMigration；AppDelegate 在掛載前做 <store>.r3-backup/backup.sqlite 一致副本，再按 metadata 版本遷移 JSON payload，保留未知欄位。失敗 rollback、離線還原、重跑及收藏／集數身份有回歸覆蓋。
- 路由／命令：BrowseSearchService 及 Workspace 搜尋六類分區，分類隨快照／分頁保留，替換取消舊查詢，空過濾頁仍保留遠端游標。Renderer／ApplicationController／Detail 傳遞完整 selection 或 subject；推薦動畫進番劇，收藏採持久分類。BangumiWorkSync 關聯前驗證動畫；非番劇不顯示或接受番劇關聯／映射，一般內容保留 generic 來源連結。DownloadService／DownloadSourceResolver 拒絕直播，不能由 video 形狀 ref 繞過。
- 正式 smoke：org.iina-ani.r3-types、隔離 HOME／CFFIXED_USER_HOME 的正式 AppDelegate。葬送的芙莉莲同名動畫／真人／書籍按 subject.type 分離；一般影片分區 21→41（Bilibili 20→40），分類／來源保持。普通 BV 解析至 480P，Forest 明示未知；關聯真人 73955 被拒絕且原 390200 保留；實際推薦 FX戰士久留美進番劇詳情。390200 手動改一般影片後退出、重啟、收藏及網址再開仍為 video/manual，兩筆 Work UUID、收藏與 Forest 連結保留。證據見 .build/r3/evidence 及 FRONTEND_REFACTOR_PLAN.md §5.5.0.3。
- smoke 發現並修正：live.bilibili.com/1010 未開播曾進入 BiliLive.decodeUrl 無串流 debug assertion 而退出133；解串流前檢查既有 info.isLiving，修正後正式 App 保留 live／房間，顯示未開播、下載停用，沒有抑制線上意外解析 assertion。最終 App PID 30337 正常退出後重啟為 30547，listener 127.0.0.1:19080；最終正常退出且 listener 消失。
- 驗證：Debug arm64 BUILD SUCCEEDED（build-final2.log）；最終 dylib SHA-256 bafe9c8119e8d4c75eb90e74027801e307f90e9fba6d0107f262240e19cc34e5。Tests/run-work-library.sh、run-w5-favorites.sh、run-w4-bangumi.sh、run-w3-sources.sh、run-w7-usecases.sh、run-workspace-layout.sh 通過，來源／用例以最後建置再跑。永久回歸限分類、游標／取消、錯關聯拒絕、手動優先、直播下載及持久身份／遷移等消費者可見風險。一次性 AX 程式／啟動腳本已清除，去敏證據與隔離 profile 保留。
- 文件／限制：同步 README、PROJECT 與前端工作文檔，R3 完成、R4–R7 保留。部分站 HTTP 403／格式錯誤及 Forest 解析失敗如實呈現，不當作播放成功；PGC 分支以回歸資料驗證。未新增站點、P2P、直播錄影或實播證據，未驗有效帳號、最低系統／Intel。未複製／刪除私人帳號／收藏；原 profile 本輪未做前後雜湊。M2／M3／MT3／M4／W8.3 不代簽。

## 2026-10-11 — 完成 R4 固定詳情格式與正式 App 驗收

- 呈現：WorkspaceDetailController 固定海報／縮圖與身份 → 簡介／資訊 → 集數／分 P → 集中播放／來源／品質／收藏／下載。番劇、一般影片、直播及未知各用對應字段，影片顯示作者、直播顯示主播／在線狀態且不顯示集數／下載／作品收藏；缺圖／簡介／年份／集數以未知或文字空狀態呈現，不留空表。
- 日常／維護：分類、Bangumi／來源關聯與映射收於預設收合的「更多」，沿用既有命令守門與身份。標題換行、海報／縮圖比例、表高依內容且有上限、缺標題／時長正規化為未知；作品載入完成不殘留載入提示。SkinAppearance 僅將 detail.media 內建標題預設字級設為 24，作者／個人覆寫照常生效，未新增 owner 或改 Registry／路由／資料模型。
- 正式 smoke：Debug arm64 BUILD SUCCEEDED，org.iina-ani.r4-detail＋隔離 HOME／CFFIXED_USER_HOME，正式 AppDelegate／實際主視窗，非 AppKit host。搜尋／網址／收藏／推薦皆進同一模板；390200 收藏退出重啟重開、545008 長雙語簡介、BV1xx411c7mD 單片、BV1wD4y1o7AS 長標題與真實第二分 P（?p=2、480P）、live/1010 未開播、Forest 遠端失敗及明確手動分類的本機缺集數作品均已操作。1280×800／960×640、淺深色及真實匯入 Contour Minimal 外觀已截圖；未勾選作者 Layout。最終來源另驗 636512 缺標題／時長顯示未知及直播專用拒絕原因。
- 回歸：Tests/run-workspace-layout.sh、run-skin-appearance.sh、run-w7-usecases.sh 通過。最終 build-final3.log、SHA-256、AX／截圖與 runtime.json 在 .build/r4/evidence；正式入口日誌確認 Core Data 位於 .build/r4/home。最終 App PID 32322 正常退出，19080 listener 已消失。臨時 AX 工具、含私人檔名的選檔树及誤命名中間圖已清除，隔離 profile／去敏證據保留。沒有新增原碼字串／wiring 永久測試。
- 文件／限制：README、PROJECT、前端計劃與 Skin 語義契約同步 R4 完成，R5–R7 保留。未新增網站／P2P／直播錄影，未按播放啟動實播或彈幕；未驗有效帳號、最低系統／Intel，原 profile 未做前後雜湊。解析可用、未開播及遠端錯誤不等於實播通過，R6 自動尋源／選單與 M2／M3／MT3／M4／W8.3 不代簽。


## 2026-10-11 — R3 域名規則與 Bangumi 二級分類

- 改動：Jibi／Dilidili 宣告番劇；移除 Forest 內建配置但保留既有收藏與來源身份。Bilibili video 統一一般影片；bangumi/play 與 Didahd／Kanba／YouKnow／Rebo 在網址與來源搜尋入口按作品標題進行匿名 Bangumi type=2 全分頁精確查詢。唯一匹配番劇、成功無匹配一般影片（影視劇）、歧義／缺標題／失敗待確認，取消向外傳遞；不自動關聯 subject ID。舊自動分類可更新，手動分類優先。
- 驗證：最終 Debug build 成功；run-w3-sources、run-w4-bangumi、run-w7-usecases、run-workspace-layout 通過。一次性程式實際查詢「葬送のフリーレン」為番劇、無匹配標題為一般影片，ss46089 經真實季 API 作品名與 Bangumi 分類為番劇。正式 AppDelegate、隔離 HOME／CFFIXED_USER_HOME 的網址搜尋顯示番劇與 unique 出處，截圖 pgc-classified.png。
- 修正／限制：正式操作發現失效預設來源／Bangumi 帳號阻擋公開分類，已將分類查詢隔離為匿名身份，原播放帳號不變。來源作品名改用已現場驗證的 PGC season API，不以分集標題分類。證據 `.build/r3-domain/evidence/`；未逐站驗證混合來源、實播、彈幕或最低系統，既有產品關卡不代簽。暫時診斷與煙霧程式清除，README／前端契約同步。

## 2026-10-11 — 完成 R5 設定層級與正式 App 驗收

- WorkspaceSettingsController：五個常駐原生 radio 分類，分類 → 設定項兩層；分類／搜尋與設定內部捲動分離，flipped 文件從頂端開始。分類欄正常字级優先 148 pt，放大字型不壓縮標題；分類／搜尋高度適應字型。沿用同義詞／分類搜尋，直接捲至／聚焦真實項目並明示目的地，清空搜尋不留過期提示。
- WorkspaceRenderer：全域 settingsController 與 Layout instance cache 分離，固定入口／側欄／⌘,／選單共用 owner，折疊設定組件後仍保留分類與搜尋焦點目的地；完整設定頁限制外層文件高度，避免導覽隨項目捲走。AppController／搜尋目錄／業務服務及 Skin／Layout 預覽套用、安全確認未另建或改契約。
- 正式 smoke：Debug arm64 build-final8.log 成功，org.iina-ani.r5-settings＋隔離 HOME／CFFIXED_USER_HOME，正式 AppDelegate／實際主視窗。五分類、1280×800／960×640 內容 pt、內建明暗與 R4 公開 fixture 的 Contour Minimal 深色、31 pt 分類／搜尋均已操作。mpv 結果點選及「缓存 清除」Enter 直接聚焦實際控制項；分類名稱搜尋、可逆偏好退出重啟、Layout 編輯折疊設定後固定入口、⌘W／固定選單重開亦有 AX／截圖證據。沒有按清理快取、播放、下載或同意 P2P。
- 回歸：Tests/run-workspace-layout.sh、run-skin-appearance.sh、run-w7-usecases.sh、既有 WorkspaceSettingsSearchRegression 通過；未新增原碼字串／wiring 永久測試。證據 .build/r5/evidence/，final-binary-sha256.txt／runtime.json 記錄最終產物。中間較早隔離 App 曾持有19080，正常退出後才啟動最終產物；最終 PID 37701 正常退出、listener 消失。暫時 AX／搜尋程式、私人 Recent Items 樹及誤命名中間圖清除。
- README／PROJECT／前端計劃同步 R5 完成；R6／R7 與 M2／M3／MT3／M4／W8.3 保留。完整 VoiceOver、有效帳號、實播／彈幕／下載、最低系統／Intel 未驗，原 profile 未做前後雜湊；31 pt 既有工作區工具列及部分原生按鈕的字形裁切保留 R7 視覺關卡，不宣稱全 App 放大字級矩陣通過。

## 2026-10-11 — 完成 R6 番劇 guest 尋源與正式實播

- AnimeSourceService 納入 App target，沿用 SourceRegistry／VideoDecoder；保存的精確作品／集數映射優先，否則 3 路有界搜尋／目錄、4 名稱、每站首頁最多 8 作品。季別／年份／型態衝突拒絕，正篇／SP／OVA／劇場版保留穩定集數身份，僅同名不自動確認。解析成功後才保存來源映射，不持久媒體 URL。
- VideoDecoder.guestSelection 清掉繼承 context 並關閉 default-account lookup；番劇不列帳號，既有動畫原生適配器 30 個 AF 請求改沿用 AccountHTTP。JSPlayer 使用非持久 store／無共享 Cookie 的 transport，保留 pinned 來源／線路／品質及非番劇顯式帳號路徑；未擴大任何來源能力。Processes 播放邊界補取消檢查並去除敏感 URL／參數日誌。
- WorkspaceDetailController／WorkspaceApplicationController／WorkspaceRenderer 共用詳情播放選單及固定命令；候選展示各站證據、集數與失敗，手動失敗不暗換，提交後不改站，取消／離頁拒收晚回應。正式驗收修復保存映射與搜尋同集因品質／線路不同而重複，以及 NSPopUpButton 同名移除引起選錯候選；同集重載通知亦不再清除提交狀態。
- 正式 Debug arm64 App、隔離 org.iina-ani.r6-sources profile：葬送的芙莉蓮 main 2.0 多候選確認、錯季拒選、保存退出重開自動播放、手動換 Jibi／XiFan、連按只提交一次、搜尋進行中取消後离頁、SP1 缺集不回退正篇均已操作。最終 XiFan mpv 1920×1080、duration 1560.976083 秒、time-pos 280.363417 → 283.366417 秒；既有 B 站直播 room 6 的 JSPlayer guest 已實播並取得畫面／loadeddata。
- Jibi 頁面可解析但媒體 TLS EOF，提交後沒有偷偷換站；不簽收該線實播。XiFan 既有能力不含 JSPlayer，UI 明示不可用；本機媒體亦非已驗證 JSPlayer 來源，不擴權。實際付費／登入來源、全站、外掛／彈幕、下載、最低系統／Intel、完整 VoiceOver 未驗；R7 與 M2／M3／MT3／M4／W8.3 保留。
- 回歸 run-w7-usecases（含 AnimeSourceRegression）、run-w2-services、run-w3-sources、run-workspace-layout、run-skin-appearance 通過。guest 回歸確認失效 default 與繼承 bearer context 都不污染公開選擇；重新尋源身份去重有 failing-before／passing-after，沒有原碼字串／wiring 測試。證據 .build/r6/evidence/、最終產物 build-final2.log／final-binary-sha256.txt；較早 debugger attach 受簽署限制 SIGKILL 後已重開，最終 PID 39704 正常退出、19080 消失。臨時工具、signed media 診斷及私人 AX 樹清除；原 profile 未做前後雜湊。README／PROJECT／前端計劃同步 R6 完成。

## 2026-10-11–12 — 交付 R7 集中結果與逐項受阻報告

- 正式來源 final7 未簽署 Debug 建置成功，macOS 27.0.1（26A434）／M4 Pro／24 GiB／12 CPU／arm64；驗收配置使用隔離 org.iina-ani.r7-acceptance HOME，正式 AppDelegate／原生視窗，不以 host 代替。前端計劃 r7-acceptance 七列矩陣／十四旅程／四狀態與品質結果；README／PROJECT 連結。原 §8 目標及 R0–R6 歷史保留。
- 修復 canonical Set／dictionary Layout digest（確認交易 failing-before／passing-after）、原生 radio／switch image 保護、暫停已知 bytes 65%／completed=1；有意義回歸與正式 AX／PNG 分列。私有 schema1 instance-state-v1.json 原子持久化、throwing 初始化／錯誤／pruning，全 caller 切換；sourceIDs 抵達前恢復 bootstrap，兩搜尋 girigiri／bilibili 修前 All／All、修後冷啟動各自恢復。Layout／Skin 不帶查詢／選中／捲動；壞檔取消保留 33 bytes，明確備份 cmp0 後恢復，workspace nil 固定入口仍可達。
- 正式雙尺寸搜尋／連點／返回、guest 芙莉蓮第2集 XiFan 真 mpv／seek／映射重開、普通 Bili mpv／直播 JSPlayer、三 Archive 完成檔與 Sintel 真暫停退出重啟恢復、非首檔尾段／取消鄰居保護；配置 fixture title→name，SourceEngine 無改動，宣告搜尋／非首檔 direct remote mpv 真實推進。v0.3 格式七項隔離庫遷移重開身份／排序穩定。Skin 原／衍生乾淨 profile 分享、26 assets一致、Layout 分離、合法64MiB／256 entries及同ID替換確認有實際證據。
- 真實午夜 NSCalendarDayChanged 背景 selector 違反 MainActor 崩潰有 .ips 根因；refreshForDayChange 非隔離接收再送主線，weak／attached 保護。final7 正式 App 臨時 DYLD background day 通知返回／主 queue 標記及 native 導覽、無注入冷啟動與 owned 19080 通過；最終 W7 回歸亦通過，探針不進永久程式。Favorites 上移跨欄／undo／redo／保存／冷重啟、預設 960 雙欄及兩私有來源冷重啟有 AX／有效圖片；native ZIP／語義壞包和有效 8192² 超像素 PNG 拒絕，原 catalog／Layout／tasks hash cmp0。
- .build/r7/evidence 保存 final7 建置／產物 hash／domain regressions、formal AX／有效 PNG、migration／export／download／capacity 及 midnight/runtime 證據。1000筆本機 AX 篩選樣本高於200ms，不簽性能；兩帳號、Bangumi真斷網／跨日新集、遠端HLS、Torrent正式全鏈、滑鼠跨欄拖曳／選中捲動冷重啟、素材替換快取、heap／constraint、全彈幕釋放、完整操作數／VoiceOver未齊，31pt裁切未修，逐項受阻。無公網P2P同意，W8.3=false；缺Intel／13.5／正式Sandbox／Developer ID／公證，M2／M3／MT3／M4／W8.3不代簽。
- 資料邊界：外部 IINA 曾開本輪公開 Huya／Archive receiver，最終僅關已識別公開視窗，PID76128保留。午夜崩潰後 open -a 誤重啟 owned PID46648 無HOME隔離、且曾佔19080；後續改成指定PID AppleEvent，最終已終止。沒有原profile前後hash，不宣稱完全未動；該輪不作驗收證據。擷取工具的menu-bar／黑圖／失敗不計通過，有效圖片與AX分列，有限privacy審核另記。一次性工具／注入／生成原碼與執行檔清除，evidence／隔離profile／包保留。

## 2026-10-12 — 發現橫向內容、密度圖標及三分類搜尋

- 發現四分區改為各自 NSCollectionView 單列水平卡片，保留原頁面縱向容器、詳情啟用、關注動態命令、實例選中及水平偏移；刷新與密度變更重用保存狀態。
- 移除組件設定文字 strip，刷新左側改為 WorkspaceDensityButton 圖標及緊湊／標準／寬鬆選單；收藏兩面板沿用獨立密度。Skin binding 保護語義原生圖標，避免被空 Skin icon 覆蓋。內建默認收藏頁排最後，不覆寫既有自訂 Layout。
- 搜尋僅番劇／視頻／直播，默認番劇；已移除的舊分類回到番劇。番劇關鍵詞僅 Bangumi，視頻／直播排除 Bangumi，包括混合站點搜尋結果的二級分類查詢；URL 精確路由及詳情／AnimeSourceService 尋源分類保持原契約。相關 BrowseSearchRegression 更新為三分類隔離、分頁、取消及過時回應行為。
- 代碼層驗證：最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED；run-workspace-layout、run-skin-appearance 與 run-w7-usecases 通過，包含搜尋、AnimeSource、來源搜尋、收藏、日常更新及下載等既有回歸。證據在 .build/ui-adjustment/evidence/build-final.log、usecases-final.log。
- 使用者中途明確要求後續只做代碼層驗證，實務由使用者自行驗證；不再啟動／操作 App，不簽收實際 UI。此前曾用獨立 Bundle ID／HOME 啟動正式 App 及除錯器擷取原生 render，發現 Skin 覆蓋密度圖標並已修正；WindowServer 黑圖／AX 無視窗不計通過。除錯器切換收藏出現原生 AutoLayout 例外，後續表達式中斷及 process 結束，原因未確定，不視為正常操作通過或已定位的產品缺陷；此實務項留由使用者驗證。未操作播放／帳號或宣稱原 profile 全量雜湊不變。
- 清除本輪臨時 AX 工具及測試 App，保留代碼層日誌與去敏 render 證據；README 更新當前搜尋與默認佈局契約。

## 2026-10-12 — 番劇資訊擴充、按鈕選集與應用內來源窗口

- 改動：Bangumi 詳情保留完整 infobox、Tags／分類標籤、評分與收藏統計；独立載入角色完整介紹、配音及關聯條目。公開短評採無帳號憑證的 HTML 分頁、逐頁快取與載入更多，拒絕驗證頁與錯誤頁碼；各區域分開保留失敗與過期快取。舊 metadata payload 缺新欄位仍可讀取。
- 介面：刪除詳情作品集數及來源目錄的表格選集，改為原生按鈕自適應網格及正篇／SP／OP／ED分組；保留 Bangumi ID／本機 Episode UUID／來源網址身份。點選作品集數或來源按鈕開啟應用內 NSPanel 子窗口，集中來源候選確認、選集、品質、線路、帳號、播放器及映射維護。關閉／取消、換集、替換詳情與 detach 隔離舊請求，保留已提交操作。
- 驗證：arm64 Debug 未簽署 xcodebuild 成功；Tests/run-w4-bangumi.sh 通過新增完整／舊payload、區域故障／快取、帳號隔離、評論分頁／空頁／驗證頁／取消以及既有同步與OAuth回歸；Tests/run-w7-usecases.sh 全部通過，涵蓋既有搜尋、精確選集、尋源、收藏、發現及下載狀態契約。證據：.build/detail-adjustment/evidence/build-final.log、bangumi.log、usecases.log。
- 限制：依本次使用者指示僅代碼層驗證，未啟動 App、操作視窗或實測來源／播放器；公開 API／HTML 的研究讀取不視為真網服務驗收，介面與播放實務由使用者驗證。


## 2026-10-12 — 移除舊播放入口並重新設計詳情排版

- 問題：前輪仍保留詳情「播放 ▾」及 App 固定播放選單；新增資訊只是沿單列逐段堆放，未完成使用者要求的頁面改版。
- 入口：移除重複播放按鈕、固定播放選單及專用 menu validation／controller 橋接／activeAnimeDetail 查詢；刪除 UI 的自動尋源啟播分支。番劇選集開啟應用內來源窗口，明確尋源與確認後只由窗口底部播放提交。普通影片既有自動開啟偏好及 Option 保留。
- 排版：頂部作品海報、名稱、精簡型態／年份／集數與評分，收藏／刷新／原始頁面／管理集中工具列；選集作為獨立主區。簡介／人物／關聯／評論分頁互斥顯示；簡介與資訊卡片在寬版雙欄、窄版上下排列，Tags 換行，人物／評論卡片及關聯分組。診斷与分類／關聯維護收進管理，主閱讀區不再展示整串來源網址及操作。來源窗口分區確認來源、選集、播放設定，播放／下載／取消／關閉列固定底部。
- 狀態：清除作品及來源後才重繪換頁資訊，避免前一作品內容留在新頁；評論載入狀態不重建已載入卡片。
- 驗證：arm64 Debug 未簽署 xcodebuild 成功；Tests/run-w4-bangumi.sh、run-w7-usecases.sh、run-workspace-layout.sh、run-skin-appearance.sh 全部通過。日誌位於 .build/detail-redesign/evidence/（build-final.log、bangumi.log、usecases.log、layout.log、appearance.log）。
- 限制：遵照使用者僅代碼層驗證要求，未啟動 App、操作介面或實測播放；版面／二級窗口操作與真網播放器驗收仍由使用者進行，不以建置或既有模型回歸宣稱 UI 實測通過。README 與 FRONTEND_REFACTOR_PLAN 更新當前入口，歷史實務證據保留而不冒充新版驗收。


## 2026-10-12 — 二級窗口自動尋源、匹配來源前台與一級鎖集

- 流程：選集／「播放所選集數…」開啟二級來源窗口即開始尋源，不再要求手動點尋找來源；唯一可信匹配自動解析並播放，多候選或作品證據不足時核對名稱、從下拉選來源即直接解析播放，刪除來源確認按鈕，不追加確認播放步驟。重開窗口重新核對保存映射，連按開窗及重選已提交的同一來源仍受 loading／commanding／generation 與單次提交保護；明確重新尋源只更新候選，不自行重播。
- 前台：AnimeSourceReport.matchedCandidates 只提供具精確來源集數且無 failure 的候選。錯季／年份／型態／缺集／停用／搜尋與解析失敗保留在預設折疊的「來源診斷與管理」；解析失敗清除前台來源及品質，不留下可播放的失效選擇。單一站失敗不遮蔽其他匹配，不增加暗換站或自動重試。
- 鎖集：番劇二級窗口不再顯示來源選集／分 P、已保存任意來源下拉或手動映射按鈕；來源及目錄 handler 同時防止更改已選作品集數，沿用 Bangumi ID／Episode UUID 到來源精確網址。品質／線路／播放器及一般影片／沒有一級集數的直接來源選集仍保留。
- 代碼驗證：最終 arm64 Debug 未簽署 xcodebuild 成功；Tests/run-w7-usecases.sh、Tests/run-w4-bangumi.sh 通過。AnimeSourceRegression 擴充前台精確候選集合、錯季／年份／型態拒絕、缺集不要求改選、部分站失敗僅保留診斷等行為斷言；既有 guest、映射、品質／線路、取消及保存回歸通過。證據：.build/source-panel-flow/evidence/build-final.log、usecases.log、bangumi.log。
- 文件：README 與 FRONTEND_REFACTOR_PLAN 更新自動尋源播放與二級鎖集契約；以上前輪手動尋源／再次確認流程記錄保留為歷史。
- 限制：依使用者要求僅代碼層建置與離線回歸，未啟動 App、操作原生窗口、連真網尋源或實測播放器；不以模型回歸宣稱 UI／實播通過，實務驗證由使用者進行。

## 2026-10-12 — 文件去重與失效引用整理

- 範圍：只整理專案 Markdown；未刪程式碼、測試、授權、依賴鎖檔、建置產物或使用者資料。
- 去重：README 的逐工作包交付長列收斂為現況與限制摘要；PROJECT 頁首重複交付記錄改指向重構規劃與本工作記錄。初次匯入的整理／雜湊／驗證標明歷史，移除已失效的暫停整體驗收敘述，不冒充本輪驗證。
- 引用：移除未收錄上游架構分析的入口，AGENT 與來源技能改指向 PROJECT 固定基線；Torrent 研究的未收錄舊 review 改為歷史說明。保留 W0、Torrent 研究、來源清單、Skin 指引及問題模板的獨有內容。
- 狀態：下載頁的 W9 整合狀態更正；新版二級來源窗口僅有建置／離線回歸的限制明示於 README，不把舊版實播當作新版證據。重構規劃中的過時狀態同步整理，契約與驗收限制保留。
- 驗證：執行 11 份 Markdown 的本機連結、目標 anchor 及程式碼圍欄檢查；本輪僅文件變更，未執行 App 建置、UI 操作、站點播放或功能測試。

## 2026-10-12 — 文件正式命名為 IINA-ANI

- 改動：README 與 PROJECT 明定正式專案名稱為 IINA-ANI，移除暫名說法；AGENT 同步文件命名規範，PROJECT 發佈表區分文件名稱與尚未遷移的工程／App 品牌。
- 驗證：搜尋專案文件，未找到「暫作專案名稱」或 IINA-ANI 暫定名稱說法；保留上游歸屬、既有技術路徑、建置指令與歷史記錄。
- 限制：僅文件更名，未變更原始碼、工程、App 顯示名稱、Bundle ID 或資料路徑；未執行 App 建置或功能驗收。

## 2026-10-12 — 工程與 App 正式更名為 IINA-ANI

- 改動：來源目錄、Xcode 工程、target／scheme、App 產物與執行檔改為 IINA-ANI；Swift module 明確設定為 IINA_ANI，同步兩份 Storyboard 的 customModule、橋接標頭與 entitlements 檔名。更新 App 選單、工作區標題、關於頁與本機網頁測試標題；同步 Tests、InstallDeps.sh、忽略規則、現行文件與來源接入規範。上游名稱、外部 IINA 協議、版權及歷史證據保留。
- 資料安全：保留 com.xjbeta.iina-plus Bundle ID 與既有偏好／服務資料佈局；Core Data 明確使用 Application Support/IINA+/DataModel.sqlite，首次啟動建立目錄，避免產品改名後跳到空白收藏庫。未遷移或清除使用者資料，也未配置獨立發佈身分。
- 工程／建置：plutil 檢查工程與 Info.plist 通過；xcodebuild -list -json 顯示工程、target、App scheme 均為 IINA-ANI。Debug arm64 無正式簽署建置 BUILD SUCCEEDED；實際產物 CFBundleName／CFBundleDisplayName／CFBundleExecutable 均為 IINA-ANI，原 Bundle ID 不變。
- 回歸：17 支 Tests／InstallDeps.sh 腳本 bash -n 通過；run-work-library.sh、run-cache-service-regression.sh、run-w3-sources.sh、run-dependency-regression.sh --unit 通過，覆蓋來源路徑、新模組／dylib 載入、資料模型遷移、快取、解析／播放編碼／Range／偏好。
- 正式 App 煙霧：執行本輪來源產物的隔離副本（只改驗收 Bundle ID org.iina-ani.rename-smoke 並 ad-hoc 重簽），使用隔離 HOME／CFFIXED_USER_HOME。實際 AX 與截图確認 IINA-ANI 主視窗、App 選單、關於頁，以及「開啟影片與彈幕」的 Storyboard 視窗。用更名前 IINA+.app 的編譯模型建立公開收藏樣本，新 App 在舊資料路徑呈現該收藏；退出後 UUID、備註與 order=7.5 保留，SQLite integrity_check=ok。另於全新 profile 啟動成功，建立可讀空庫。三次驗收 App 均經正式結束選單退出 exit 0；未啟動外部播放器或 P2P。
- 證據／清理：去敏 AX、PNG、工程方案與建置／回歸結果保存於 .build/rename/evidence/；移除本輪一次性 smoke 工具、測試 App、副本 profile 與原始 App 日誌。
- 限制：僅 Debug arm64 與更名相關正式入口驗證；未重新驗收 JSPlayer 實播、彈幕、下載、帳號、Intel、最低 macOS、Release 或正式簽署／公證。隔離 guest 動態查詢仍回 data.mid 缺失，不把品牌／收藏驗證當作站點成功或全產品驗收。

## 2026-10-12 — 追番背景來源的 css1 訂閱更新

- 定位：依使用者確認，以一站式追番為重點；後續測試站點是可替換來源，不追求清單每站可用，不新增清單站點帳號，保留原專案帳號及既有播放／目錄解析器。
- 實作：新增 SourceSubscriptionConverter 與 AppServices 擁有的 SourceSubscriptionService；受控下載固定 HTTPS 訂閱，限制資料大小／項目／選擇器，接受 web-selector v2 的已核准搜尋欄位。固定 host 身份映射、Hanime 畫質變體合併、Forest 排除；保留海星／風車選擇器、櫻花／熱播網址及本地分頁修正。未知域名／解析格式／衝突不猜測，不匯入 Cookie、token、腳本或媒體嗅探規則。
- 更新安全：設定頁提供檢查、欄位差異預覽、明確套用／捨棄、取消及最近套用版本；變更規則用公開搜尋驗證可辨識作品，失敗項保留舊版。SourceRegistry 以世代拒絕過時預覽、先原子落盤再發布快照；訂閱存於 sources/subscriptions/css1.json，不覆寫一般來源 JSON。缺項保留已安裝配置；作品／集數身份、收藏、活動播放與下載不變。VideoDecoder 的原生與 Fqdm 搜尋讀取有效覆寫，追番尋源沿用既有訪客入口。
- 建置／回歸：最終 Debug arm64 xcodebuild 成功；Tests/run-w3-sources.sh 全部通過，含新增轉換與持久化回歸：安全欄位、已核准 host、重複衝突、未知／缺項、身份保留、跨實例恢復、過時預覽、原站隔離、壞檔重載與寫入失敗原子性。
- 聯網煙霧：真實 css1 為 18 項，接受 16 個搜尋身份、Forest 排除，現行配置全數未變更。明確套用並建立新 Registry 後恢復 16 項；VideoDecoder 搜尋「海贼王」取得稀飯 3 筆、海星 24 筆及下一頁。另在隔離基線將 Jibi 選擇器設為舊規則，真實訂閱檢查成功驗證並套用新選擇器；稀飯不存在選擇器的真實搜尋探測未通過，原有效規則及其他來源覆寫保留。
- 正式 App：啟動本輪建置的隔離副本（驗收 Bundle ID org.iina-ani.subscription-proof、CFFIXED_USER_HOME 與獨立埠），走正式 AppDelegate。AX 操作與 PNG 確認檢查→18 項預覽→套用、再次檢查／取消、捨棄、最終版本重啟恢復及重載清除舊預覽。未終止既有使用者 App，未修改其偏好、收藏或來源資料。
- 文件／證據：README、PROJECT、FRONTEND_REFACTOR_PLAN 同步產品定位、操作、持久化與支援邊界；建置、回歸、聯網結果與視窗證據位於 .build/subscription/evidence/。移除本輪暫存程式、原始訂閱、隔離 App／profile 與原始 App 日誌。
- 限制：本功能更新公開搜尋配置，不是任意新站／遠端播放規則的通用引擎；未知站仍明示不支援。未重驗全站播放、下載、彈幕、帳號、完整 VoiceOver、Intel／最低 macOS 或正式签署；不以搜尋／訂閱成功宣稱完整追番或全站可播驗收。

## 2026-10-12 — 舊來源與個人資料雙層隔離測試

- 使用者選擇「兩者都隔離」。SourceRegistry 增加測試副本的 SourceSubscriptionRequired 門檻：後加的 16 個來源在未套用訂閱前不宣告搜尋能力，原生搜尋取值也不能取到舊規則；Fqdm 同受 VideoDecoder 能力門檻限制。內建規則僅作轉換基線，原專案來源及直接網址解析保留。套用後只啟用接受的來源，缺項不啟用，重啟保持邊界。普通 App 預設行為不變。
- 預覽待啟用來源明示「待啟用」；設定頁標示隔離狀態。測試副本裸啟動若沒有隔離入口標記，在 AppDelegate／資料服務建立前顯示提示並返回，避免意外讀取原資料。
- 交付：.build/subscription-isolation/IINA-ANI.app 使用獨立 Bundle ID org.iina-ani.subscription-sandbox、ad-hoc 簽署；同目錄「啟動訂閱測試.command」設定獨立 HOME／CFFIXED_USER_HOME、隔離標記與埠 29292。使用者資料留在 home/，沒有搬移或刪除舊偏好、收藏、帳號或配置。應關閉測試 App 後再以同入口重開。
- 驗證：最終 Debug arm64 建置與來源回歸全通過；新增隔離模式測試涵蓋原站保留、未套用無搜尋能力／Fqdm 直接服務拒絕、套用只啟用該站及重啟。獨立 verification-home 的正式 App 完成真實訂閱預覽／套用，AX 確認 xifan／fqdm 由無 search 轉為有 search；裸啟動安全提示已截圖。
- 乾淨交付：另以全新使用者 home 啟動最終 App，停在「來源與帳號」。AX／PNG 確認隔離提示、尚無套用記錄、後加來源無搜尋能力；home 下無 css1.json。驗證時已套用的 profile 不供使用者測試，已清除。使用者測試 App 持續運行。
- 文件／證據：README 已記錄入口與門檻；證據位於 .build/subscription-isolation/evidence/。移除一次性 AX 輔助程式與 verification-home；保留交付 App、啟動入口及乾淨 user home。未重新驗收全站播放或更改正常 App 的資料。

## 2026-10-12 — 訂閱正式切換與跨動畫播放進度隔離

- 來源：依使用者已完成新来源測試的回報，將 css1 訂閱設為後加 16 個來源唯一搜尋／自動尋源入口；移除 requiresSubscription／SourceSubscriptionRequired 測試開關、AppDelegate 專用啟動攔截及原生／配置來源的舊搜尋 fallback。舊搜尋規則僅保留轉換基線；未套用來源不宣告 search，原專案來源、直接網址解析及播放／目錄適配器保留。沒有刪除或搬移使用者偏好、收藏、帳號及先前隔離測試資料。
- 播放：PlaybackEncoder.iinaPluginUrl 不再用 JSON 參數尾端 25 字元當作代理網址識別，改用既有 media.uuid 作獨立會話，初次 URL scheme 明確傳 mpv_start=0。外掛內的同片品質／線路切換參數未改，不清除 IINA 全域觀看紀錄。回歸涵蓋不同媒體／同名標題不共用代理身份、同份解析身份穩定與新播放從零開始。
- 建置／回歸：Debug arm64 xcodebuild BUILD SUCCEEDED；Tests/run-w3-sources.sh 全部來源／訂閱回歸與 Tests/run-dependency-regression.sh --unit 通過。新增來源預設只走訂閱、保留 resolve／原站搜尋、套用後啟用原生與 configured 搜尋的永久回歸。
- 正式 App：本次產物的隔離副本 org.iina-ani.cutover-proof 經正式 AppDelegate 啟動；AX 與 PNG 確認來源設定已無測試模式文案，未套用時 xifan／fqdm 無 search；真實訂閱檢查顯示 18 項／16 個可套用配置、待啟用，明確套用後兩者恢復 search。驗證副本以正式結束選單退出 exit 0。
- IINA 實播：使用安裝版 IINA 的隔離副本及既有 Danmaku 0.1.21 外掛，由本次生產模組編碼兩段自行生成的 60 秒影片。透過真正 URL scheme／外掛 on_load 轉址載入，第一部 seek 到 35.0 秒並寫入 watch-later，停止後在同一 IINA 程序開第二部；IPC 確認第二部 time-pos=0.1 秒、已解碼 320px 視訊，保存實際畫面。額外臨時觀測外掛僅開 IPC，未更動既有外掛播放逻輯；初次 URL scheme 傳 IPC 被 IINA 安全限制拒絕，改用隔離觀測外掛後驗證成功。使用者原有 IINA／IINA-ANI 未被退出或接管。
- 文件／證據：README、PROJECT、FRONTEND_REFACTOR_PLAN 同步當前入口與播放契約；建置、回歸、AX、PNG 與去敏 IPC 結果保存 .build/playback-cutover/evidence/。清除本輪一次性程式、媒體、測試 App／profile 與原始 App／IINA 日誌，保留正式 .build/xcode 產物。
- 限制：本輪驗證新來源入口、真實訂閱套用與兩部合成影片切換；不重做使用者已完成的遠端播放源驗收。未逐站重驗遠端媒體、同片品質切換、彈幕、下載、Intel／最低 macOS 或正式簽署；不把設定套用或合成影片證據當成全站可播宣稱。

## 2026-10-12 — 使用 css1 原始鏈接修復來源匹配

- 問題：SourceSubscriptionConverter 對櫻花／熱播忽略訂閱 searchUrl，強制換成舊基線網域；SourceSearchExecutor 在 HTTP 重新導向後丟棄最終回應網址，搜尋結果／封面等相對連結仍依原請求地址解析。
- 修正：全部受管來源使用已驗證的 css1 searchUrl，不再對兩站覆寫網域；搜尋 HTTP 同時回傳資料與經白名單驗證的最終 URL，HTML／JSON 相對連結以回應 URL 解析。既有來源身份、核准 host／HTTPS 安全邊界、搜尋→作品→精確集數匹配與手動確認政策不變。舊已保存訂閱需重新檢查並明確套用，不暗中改寫使用者快照。
- 回歸：刪除只檢查複製基線欄位的斷言；新增櫻花／熱播實際 requestURL 保留訂閱 host、特殊字元查詢及分頁的契約回歸。Debug arm64 xcodebuild BUILD SUCCEEDED；Tests/run-w3-sources.sh 全部通過。
- 真實煙霧：載入本次生產 App 模組，使用下載的公開 css1，走 SourceSubscriptionService.check／apply、VideoDecoder.searchSource 與 AnimeSourceService.discover。櫻花請求 www.yinghua2.com、回應候選 www.yinghuabb.com（10 筆）；熱播請求 www.rebozj.pro、回應候選 www.rebozj.cc（2 筆）。「海贼王」匹配櫻花 main 第 1 集的 nid=1 精確 URL；熱播兩筆真人版及櫻花其他同關鍵詞作品維持拒絕，不誤選影片。最終 smoke exit 0。
- 驗證工具修正：最初 smoke 錯誤要求兩站皆有同部動畫而失敗；實際熱播僅回傳真人版，來源服務正確拒絕。改為驗證櫻花精確集數與真人版排除，不改產品分類／匹配條件來迎合驗證。
- 文件／清理：README、PROJECT 同步鏈接與重新套用方式；證據位於 .build/source-links/evidence/。移除一次性 Swift／編譯腳本、原始訂閱／網頁與隔離資料，未動個人收藏、訂閱或帳號。
- 限制：本輪是來源／訂閱回歸及真實網路服務鏈驗證，未另操作正式 App UI、啟動播放器、下載或逐站驗證所有動畫；不把成功匹配當作媒體實播通過。


## 2026-10-12 — 番劇名稱保守模糊匹配

- 根因：以正式 App 看到 subject 639938「飙马野郎 JOJO的奇妙冒险 第二&第三赛段」第 2 集沒有前台候選；完整診斷與實網服務確認 Senfun／Wedm 等已命中合併標題，但舊作品名稱比對在讀集目錄前直接拒收。使用者明確要求適當模糊搜尋，未以放寬播放／內容分類邊界掩蓋失敗。
- 修正：AnimeSourceService 統一繁簡／大小寫／標點、結構化比較尾端賽段，容許完整標題成分換序及長名稱少量文字差異；近似、換序或未標分段只列手動候選。四個搜尋詞優先官方完整名、去限定名稱與完整短關鍵詞；不相關命中不占八個可評估作品名額，另保留有界拒收診斷。匹配證據只計算一次，仍排除明確不同季別／分段／年份／型態。
- 驗證：永久回歸以舊模組執行時，合併標題候選 case 明確失敗；修正後 AnimeSourceRegression、run-w7-usecases 通過。真 css1 check／apply→VideoDecoder→AnimeSourceService，639938 第 2 集由零候選變為八個精確第 2 集頁候選，未產生 automatic；錯第一賽段仍拒收。證據在 .build/episode-source-fix/。
- 限制：本次不是逐站媒體播放證明。正式 App 的問題頁面曾直接觀察並截圖；修改後自動 UI 操作未完成，使用者要求停止接管，後續視窗及實播留給手動驗證。

## 2026-10-12 — 多證據跨季度與合併分段編號映射

- 問題：只拿 Bangumi sort 對來源目錄，會找不到每季重新編號的來源；若反過來一律使用條目內第 1 集，則會把 JOJO 第二部分錯播成合併來源的第一部分。官方 API 的 ep 欄位此前沒有保存。
- 資料：BangumiEpisode 保存 optional ep，sort、官方 episode ID、本機 Episode UUID 與已保存來源映射均保留。BangumiService 與 BangumiWorkSync 的兩層新鮮快取都會為缺 ep 的舊主線 metadata 抓取官方回填；離線沿用 stale fallback，不從列表下標偽造 ep，不改寫收藏或手動關聯。
- 判定：來源每線路單獨核對作品季別／賽段、主線編號範圍及唯一官方集名。明示同季／同分段且從低號重啟者用 ep；有連續範圍證據或未標分段合併者保留 sort。完整集名可作手動錨點，其他集名也可建立編號方式；SP／OP／ED 不套用主線偏移。同號或同名對應多個不同頁面、同線路錨點衝突、無法區分的重疊編號與合輯範圍不猜測，不按來源排列／decoder index 換算。
- 真網：最新正式 App 模組走真 css1 check／apply、官方 metadata、來源搜尋及目錄。藥屋第二季 486347／episode 1415053（sort25、ep1）取得四個來源第 1 集候選；第三季 568244／episode 1738547（sort49、ep1）取得 Jibi 第 1 集候選；JOJO 639938／episode 1663677（sort2、ep1）取得 Jibi／Senfun 三個合併來源第 2 集候選，XiFan 明確第一賽段仍拒收。三項 VERIFY PASS；全部保持 guest、automatic0。每線路原始順序／範圍／頁身份證據在 .build/episode-number-fix/。
- 回歸／建置：Debug arm64 xcodebuild BUILD SUCCEEDED；Tests/run-w4-bangumi.sh、Tests/run-w7-usecases.sh 全部通過。新增覆蓋分季與連續來源、JOJO 合併／分段、倒排／SP、長季編號重疊、季別分組、唯一與矛盾集名錨點、不同線路、合輯拒收、無官方身份禁止偏移、持久映射 UUID 及新舊快取／離線回填。
- 邊界：使用既有 Bangumi 官方 API 與公開來源目錄兩侧證據，沒有引入需登入／API key 的第三方服務或假映射 fallback；缺可信資料時保留診斷。遵守使用者手動驗證要求，本輪沒有操作／重啟其正在使用的 App，也未啟動播放器或驗證實播。新建置須由使用者方便時重啟載入；不把服務鏈成功宣稱 UI／媒體全鏈通過。
- 清理：一次性 Swift／shell 操作與 smoke 工具、測試二進位及原始 API 資料已移除，保留建置／回歸／真網日誌與畫面證據；沒有刪除正在供使用者手動驗收的 .build/episode-source-fix/home 或操作其行程。


## 2026-10-12 — 使用者確認來源匹配可用並結案

- 使用者完成手動驗證後明確回報「以確認可用，記錄工作並結束」；本輪名稱模糊匹配、跨季度雙編號及 JOJO 分段／合併來源修正依此回報結案。
- 此為使用者手動驗收結果，與上述助理執行的建置、離線回歸及真網服務驗證分開記錄；使用者未列明所有驗證站點、線路或播放／彈幕細項，不擴大為全站與所有播放器驗收通過。
- 依要求不再操作視窗、不重啟 App、不追加測試或程式改動；保留既有使用者資料與驗證證據。

## 2026-10-13 — 修復登入退出、精簡帳號與訂閱子窗口

- 改動：Bilibili／鬥魚登入的取消按鈕移至網頁外的固定底欄並支援 Esc；Bangumi 移除無效的 SwiftUI environment dismiss，改由 AppKit owner 明確關閉，授權前後均有 Done／Esc。移除 Bangumi 重複刷新／登出視圖及死方法，登出集中於設定。
- 帳號：設定只留三站狀態、已登入名稱與登入／登出，移除號池、新增／預設切換、啟停、UUID／lease 管理和來源能力／重載明細。重用既有預設或待登入身份，不刪其他舊身份／憑證。活動使用中仍由服務原子拒絕登出。直播／影片來源窗口刪除帳號選單及切換處理，只讀已登入／未登入；停用或失效不計作已登入，播放／下載保持 pinned accountID，不暗改訪客。
- 訂閱：css1 檢查、差異列表、套用／捨棄及取消移至 Skin 綁定的独立子窗口；主設定僅入口。關閉／Esc／detach 取消檢查並清除窗口預覽，明確套用才保存。README、PROJECT 與現行 UI 契約同步；搜尋回歸移除舊帳號 destination 與文案綁定断言，保留多詞匹配、大小寫／空白、身份及未知查詢行為。
- 建置／回歸：Debug arm64 正式 App xcodebuild BUILD SUCCEEDED；WorkspaceSettingsSearchRegression 通過。首次建置遇到背景修改的中間狀態而失敗，完整修改後建置通過；未宣稱全套回歸或最低系統通過。
- 正式 App 驗證：啟動新產物並確認其 executable 路徑；原資料三站已登入狀態正常。css1 真網檢查取得 18 項／16 個配置，實測取消、關閉、重開清除預覽。Bilibili 1010 房間未開播，來源子窗口顯示已登入且無帳號選單。未啟動播放器。
- 隔離驗證：使用同一新建置產物的 App 副本，僅改驗證 bundle ID／HOME 以隔離偏好與 Keychain，仍走正式 AppDelegate。Bilibili／鬥魚取消按鈕及 Esc、Bangumi 授權前 Done 與載入官方登入頁後 Esc 均關閉 sheet，觀察 sheet 數為 0；每站反覆開啟後本機只保留 1 個待登入身份。css1 明確套用成功；訪客直播窗口顯示未登入且無帳號選單，訂閱窗口 Esc 可退出。沒有提交登入或刪除使用者憑證。
- 證據／限制：建置日誌、AX 狀態及實際畫面保留於 .build/account-ui/；本輪未完成登入提交、真人登出、活動 lease 拒絕與失效／停用的完整 UI 矩陣，未驗證播放／下載／彈幕或最低系统。已恢復正常 bundle 與原資料入口；一次性驗證工具、App 副本及其隔離資料清除。

## 2026-10-13 — 發現／收藏佈局與無限下滑推薦

- 佈局：發現頂端為 Trends 水平卡片，新增 `discovery.feed` 垂直自適應網格，使用剩餘空間；頂端按既定高度顯示，不再與推薦等高。Favorite updates 移至收藏頁頂端，原作品／連結雙欄、排序與資料保留。Bilibili 關注動態仍由功能選單可達。
- 日曆：改由右上角圖標按鈕開啟 760 × 380 彈窗，可再按按鈕、點外側或 Esc 關閉；開關與預覽隔離沿用既有能力政策，关闭取消面板查詢，不停止共用日常刷新。
- 推薦：第一頁保留網站 Trends 順序，下方從第二頁真實分頁接續；按 subject ID 去重，捲到末端自動載入，也提供手動載入／錯誤重試。頁面快取及身份隔離，公開請求不帶 Cookie／OAuth，依同源 pager 判斷末頁，不複製舊卡片製造無限列表。切頁取消專屬請求、保留已載入內容与捲動。
- 遷移：原子遷移仍符合舊三／四分區內建發現＋雙欄收藏結構的 base／全部 breakpoint，保留頁順序、標題、存續實例 ID、收藏 split、導覽與折疊設定；任一斷點自訂尺寸／結構／順序／參數／契約即不覆寫。正式 App 首次操作發現現用三分區版本，補上此舊版遷移並通過永久回歸。
- 互動：正式 UI smoke 發現卡片標題的可選取文字攔截雙擊；卡片文字改為不可選取，使用明確雙擊手勢取得卡片索引後開啟詳情，保留 Return 啟用。實測推薦「碧蓝之海 第三季」開啟真實作品資訊與集數，返回後推薦保留。
- 驗證：Debug arm64 正式 App 建置成功；`Tests/run-workspace-layout.sh` 通過（遷移、身份與設定、全部斷點、自訂保護、持久重讀／冪等）。`Tests/run-w4-bangumi.sh` 通過 service／work-sync／OAuth，含分頁 cache／邊界／隔離／錯誤／取消；真網分頁 smoke page 1／2 各 24 且有下一頁、page 42 為 16 且結束、page 43 為空且結束。
- 正式 App：走 AppDelegate、原資料與实际視窗，驗證現用佈局遷移、Trends 頂置、收藏更新移置、日曆開關／Esc、960 寬視窗推薦網格；捲动自動載入 page 3／4，推薦累積 24 → 48 → 72 且顯示不同作品。實際畫面、AX 與建置日誌保留於 `.build/discovery-layout/`；不以回歸測試冒充原生 UI 驗收。
- 文件／限制：README、PROJECT、現行 UI 契約與 Skin 組件表同步。日曆真網本輪回報「Bangumi 日曆暫時無法取得」，已驗證彈窗尺寸及錯誤呈現，未聲稱排期資料成功；收藏庫當時無作品更新，僅驗證分區移置及原連結仍在。未驗證播放／下載／彈幕、最低系統、Intel 或正式簽署。一次性操作工具清除，保留使用者帳號、收藏、來源設定與播放器。

## 2026-10-13 — Bangumi 頁面調用確認與每日放送解碼修復

- 調用確認：日曆按鈕建立 `discovery.schedule` 面板，經共用 `DiscoveryService.presentationSnapshot`／`refresh` 呼叫 `BangumiService.calendar`，依當地星期篩選動畫並另取主封面；Trends／推薦流讀公開動畫 browser，作品關鍵詞搜尋走 v0 search，詳情的元資料、角色／關聯及公開短評分開請求。Bilibili 番劇解析不屬於這條 Bangumi 元資料鏈。
- 根因：真網 `GET https://api.bgm.tv/calendar` 回應 200，但日曆的 `rating` 沒有 `rank`，`collection` 只提供 `doing`；共用模型把排名及所有收藏統計設為必填，導致整份日曆解碼失敗。直接使用 App dylib 解碼該回應，定位 `DecodingError.keyNotFound` 於 `[0].items[0].rating.rank`。
- 修復：`BangumiRating.rank` 及收藏統計改為可選，缺失保留 nil；詳情不顯示缺失排名，未提供的收藏統計顯示未知而非 0。不吞掉其他 schema／網路錯誤、不清除使用者資料或憑證。README 同步資料語義。
- 回歸：新增 `legacyCalendarStatistics`，涵蓋舊版日曆缺失排名／部分收藏統計、排期及已發布數據保留，以及落盤後離線快取重讀；`Tests/run-w4-bangumi.sh` 的服務、作品同步與 OAuth 回歸全部通過。Debug arm64 App 建置成功。
- 正式 App：重啟本次新建置產物，走 AppDelegate 與原資料入口；日曆顯示今日 10 部作品，Dark Machine The Animation 等作品的封面／標題可見。關閉重開及日曆面板 Refresh 後仍顯示 10 部；實際畫面與 AX／建置證據保留於 `.build/bangumi-calendar-fixed.png`、`.build/bangumi-calendar-fixed.ax.txt`、`.build/bangumi-calendar-refresh.ax.txt`、`.build/bangumi-calendar-fix-build.log`。此證據補足上一筆日曆排期資料未成功的限制，不改寫歷史記錄。
- 限制／清理：未驗證播放、下載、彈幕、最低系統、Intel 或真人登入；既有無關建置警告仍在。一次性網路／解碼／AX 程式及其輸入／二進位清除；正式 App 保持修正版運行。

## 2026-10-13 — 日曆改為全週放送

- 資料：官方 calendar API 排期不再過濾今日，改為週一至週日排序、每日去重，跨日同作品保留；全週按唯一 subject ID 取得主封面並回填，沿用四並行／24 小時快取。契約 clean cutover 為 DiscoveryScheduledBroadcast／weeklyBroadcasts，相關呼叫端與回歸同步。
- 介面：日曆彈窗改 760 × 520 垂直自適應網格，預設全週，提供全週／週一至週日篩選；星期切換只使用已載入 snapshot、重置捲動與選擇，不重發 API。每筆顯示星期，空排期仍有明確空狀態。
- 驗證：Debug arm64 App 建置成功；Tests/run-w7-usecases.sh 與 Tests/run-w4-bangumi.sh 全部通過。Discovery 回歸涵蓋亂序週、同日重複、跨日保留、空日／空週、共用封面及取消。正式 App 顯示全週 105 筆，週一至日篩選依序顯示 11、10、12、11、14、21、26 筆及正確星期作品，還原全週。
- 文件與證據：README、PROJECT、FRONTEND_REFACTOR_PLAN 更新全週契約；建置／回歸／AX 與畫面保留於 .build/week-*。一次性 AX 工具清除，修正版 App 保持運行。
- 限制：真網有 3 部主封面取得失敗，排期保留且 UI 明示錯誤；未驗證播放、下載、彈幕、最低系統、Intel 或正式簽署。既有共用刷新／詳情生命週期風險未在本需求擴大修改。

## 2026-10-13 — 日曆改為源站式七欄網格

- 介面：移除全週／星期 segmented 篩選及死狀態；第一行固定為「周日｜周一｜周二｜周三｜周四｜周五｜周六」，全週排期按天對應七欄，上方表頭在捲動區外。卡片改海報在上、最多四行標題在下；每欄保留自身順序，較短欄尾端留空且不可選取，不把後續作品移至其他星期。總數只計真實排期，不計留空格。
- 驗證：Debug arm64 建置成功並重啟正式 App；AX 及實際畫面顯示固定七欄順序與對應星期首部作品，全週真實數為 105。使用者已確認畫面，依確認停止後續反覆 UI 操作。自動捲動及作品雙擊本輪未完成動態驗證，不把操作工具的發送事件當成通過；相關原有開啟鏈保留。
- 文件：README、PROJECT、FRONTEND_REFACTOR_PLAN 同步固定第一行與七欄語義，保留上輪歷史驗證。未更動官方 API、全週排期／封面快取或使用者帳號資料。一次性 AX 工具清除，證據保留於 .build/calendar-grid-*。
- 限制：3 部主封面缺失仍明示且保留排期；本輪未重跑上輪 W7／W4 測試，未驗證播放、下載、彈幕及最低系統。

## 2026-10-13 — 卡片懸浮資訊與滑動方向衝突改善

- 呈現：Trends／推薦卡片平時只顯示作品名稱，來源與推薦說明收進原生 toolTip／輔助說明；Bilibili 關注動態收起作者、觀看數、時長與分 P 資訊。收藏更新保留作品與新集數，僅收起來源。日曆標題、搜尋分類、錯誤與載入狀態維持可見，沒有刪除業務資料。
- 捲動：新增共用 WorkspaceScrollView，接入外層工作區、服務面板、收藏、詳情及設定主內容／搜尋結果。每個手勢固定主要方向與接收面板，慣性尾段不重新分流；只去除非主要方向 delta，沿用 AppKit 原生捲動。發現頁 Trends 的縱滑交給下方推薦，橫滑留在卡片；Layout 重繪清除舊目標，隱藏／卸載面板不接收分流。
- 驗證：兩次 Debug arm64／無正式簽署建置均 BUILD SUCCEEDED。使用本輪來源產物的隔離 bundle／HOME 副本，走正式 AppDelegate 與實際 Workspace；AX 確認標題可見且完整說明保留，實際截圖確認原生懸浮提示顯示。原生事件＋AX 狀態斷言通過斜向橫滑、Trends 上縱滑、同一手勢改變 delta 比例、慣性尾段與下一個反向手勢；橫滑時推薦 scrollbar 不變，縱滑時 Trends scrollbar 不變。最後分流清理改動編譯通過；使用者已確認，本輪依確認停止後續 UI 操作。
- 證據／清理：保留 .build/page-effects/ 的 scroll-proof.log、AX／PNG 與 .build/page-effects-build*.log；隔離 App 正常退出 0，清除本輪一次性操作程式、二進位、App 副本與隔離 HOME。README 補操作契約；未修改使用者收藏、帳號或來源配置。
- 限制：未重驗播放／下載／彈幕、真人登入、最低 macOS／Intel、正式簽署或實體觸控板手感。隔離 App 的本機播放 listener 因既有埠占用未啟動，此輪不宣稱播放服務驗收；日曆已開啟觀察，但後續捲動時彈窗關閉，該動態操作不計通過。

## 2026-10-13 — 番名固定濾鏡懸浮浮窗

- 呈現：Discovery 共用卡片改為封面居中、保持 2:3／16:9 比例，平時隱藏番名；鼠標移入卡片時，在卡片固定位置顯示 hudWindow 深色毛玻璃與固定 45% 黑色濾鏡、15 pt 白色半粗體番名，0.18 秒淡入／淡出，不跟隨鼠標、不另開窗口且移除舊系統 toolTip。Trends、推薦、全週放送、更新與關注動態沿用同一視圖；新集數提示維持直接可見，搜尋／收藏列表與詳情正文不隱藏名稱。
- 行為：長番名依寬度換行；鍵盤導覽選中卡片可顯示同一浮層，減少動態效果時直接切換。名稱與原有來源說明保留在單一 AX 元素，浮層不攔截選中／雙擊；空日留白不顯示浮層，重用時恢復 accessibility 身分。修正實測發現的單行截斷，以及日曆開啟／換卡時初始懸浮狀態殘留；同一 collection 的鼠標懸浮接收者互斥。
- 驗證：最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED；以本輪產物的隔離 bundle／HOME 副本走正式 AppDelegate 與 Workspace。實際移入／移出／再次移入截圖確認濾鏡與文字浮現、移出消失；日曆最長首項名稱完整換行，切至航海王後只剩當前卡片浮層。雙擊羅梅莉亞戰記後 AX 與畫面顯示對應真實作品詳情，返回可再開日曆。沒有用隔離 host 或舊產物代替最終 UI 證據。
- 文件／清理：README 與前端呈現契約同步；保留 .build/hover-title/ 的最終 AX／PNG、verify-final.log 與 .build/hover-title-build-final.log，隔離 App 正常退出，清除一次性 AX 程式／二進位、App 副本及隔離 HOME。未清除或改寫使用者帳號、收藏與來源配置。
- 限制：未驗完整 VoiceOver、键盤所有路径、系統降低動態效果切換、全部 Skin／放大字級、最低 macOS／Intel／正式簽署；未重驗播放／下載／彈幕。初始驗證副本的本機播放埠曾因既有行程占用而不可用，不據此宣稱播放服務驗收。

## 2026-10-13 — 懸浮番名底置與濾鏡透明度調整

- 改動：浮層番名由垂直置中改為底置，底邊位於新集數提示上方 8 pt，保留換行及 0.18 秒淡入淡出。濾鏡／文字分層，hudWindow 毛玻璃不透明度調為 55%，黑色疊色由 45% 降至 18%；文字保持不透明，不隨背景一起變淡。
- 驗證：Debug arm64／無正式簽署建置 BUILD SUCCEEDED；以本輪來源產物的隔離 bundle／HOME 副本走正式 AppDelegate 與實際 Workspace。實際鼠標移入截圖確認番名位於卡片底部、濾鏡下封面細節可見、文字維持白色清晰；移出後浮層及番名消失。證據 .build/hover-title-bottom/ 的 hover-bottom.png、idle.png、leave.png、verify.log，以及 .build/hover-title-bottom-build.log。
- 文件／清理：README 與前端呈現契約同步，隔離 App 正常退出並清除一次性 AX 程式／二進位、App 副本及隔離 HOME；不改使用者帳號、收藏與來源配置。
- 限制：本輪未重驗日曆長番名、鍵盤／完整 VoiceOver、所有 Skin／放大字級、降低動態效果切換、播放／下載／彈幕或最低系統；不沿用上一輪視窗證據作為本輪全矩陣驗收。

## 2026-10-13 — 主頁緊湊密度與實際播放續看

- UI／Layout：內建首頁順序改為 Trends → 繼續觀看 → 推薦，Trends 210 pt；卡片邊距 2 pt、間距 4 pt，封面比例不變形地填滿裁切，推薦在正式 960／1280 視窗分別有效呈現 5／8 欄。保留底置白字、55% 毛玻璃與 18% 黑色疊色；續看單行直接顯示作品／集標題、實際位置和已知時長進度，未知時長不偽造百分比。空列收為 76 pt 提示。playback.continue 完整接入 registry、內建 Layout、編排／Skin；僅全部斷點仍為精確舊三／四區或 Trends／推薦兩區者遷移，共享新增續看身份，保存存續 instance ID、導航、折疊與私有密度／選中／捲動，自訂 Layout 不覆寫。
- 後端：PlaybackHistoryStore 保存原選擇與實際觀察秒數，私有檔案為 Playback/history-v1.json；不保存短效串流、Cookie、token 或 accountID。IINA／mpv 每窗 IPC、JSPlayer 的位置／完成事件接入 owner；首頁觀察通知，點選透過 AppServices.resumePlayback 重新解析並定位，直播不建立續看記錄。正式App發現local與集標題空字串，修正local解析／下載入口以真實文件名供標題、保存與重讀正規化舊空 metadata，位置不變；不以UI假資料掩蓋。
- 回歸／建置：本人執行 bash Tests/run-workspace-layout.sh，嚴格身份／尺寸、兩尺寸首頁順序、舊三／四區及兩區全部斷點遷移、原子重開／冪等與自訂佈局保護皆 PASS。向後端作者索取並讀取證據：.build/continue-watching-unit-metadata-final.log 五組 PASS（播放編碼、分數秒／重啟／隔離／完成／憑證排除／真文件名／舊空 metadata、來源、Range、偏好）；最終 xcodebuild Debug arm64／CODE_SIGNING_ALLOWED=NO 為 BUILD SUCCEEDED（.build/continue-watching-build-metadata-final.log:2804）。後端 node --check flvplayer.js PASS；真 mpv 服務鏈 actual/save 39.291667 秒 → 新owner/AppServices重新解析續播 actual 41.333333 秒（.build/playback-history-smoke/evidence.json），自然 EOF 與重開空歷史 PASS（.build/continue-watching-eof.log）。
- 正式App實播：使用上述最終來源产物的隔離bundle/HOME副本，走正式AppDelegate和Workspace，不用host代替。從本地120秒真影片經搜尋→詳情→來源窗口播放，IPC觀察／保存45秒後正常退出；最終build重開，續看卡顯示 fixture.mp4／影片／0:45／2:00。單擊卡片確實啟動mpv並從45秒播放；再關閉於58.583333秒，首頁再次單擊後即時IPC為58.75秒（差0.166667秒，非URL提交假成功）。seek119.5後讓影片自然播完，同一App通知即移除續看項、持久entries為空且列收緊，兩尺寸均可用。證據 .build/continue-ui/formal-playback-evidence.json、final-reopen-1280／final-progress-960／final-empty-960／final-empty-1280／final-hover-1280 PNG及對應AX。
- 原生手勢：最終App實際事件與AX確認，Trends橫向位移時推薦document y保持75，改變delta比例／慣性尾段仍同owner；新縱滑時Trends scrollbar保持0.264084507，推薦document y由75→-135，亦觸發正常推薦分頁。分頁令normalized scrollbar分母改變，故使用實際document位置而非假設normalized值只會增加。續看上橫向手勢未移動推薦，縱向手勢確實分流推薦且Trends不動。證據 .build/continue-ui/final-trend-gesture-*.ax.txt、final-continue-gesture-*.ax.txt。
- 文件／清理：README、PROJECT、FRONTEND_REFACTOR_PLAN與Skin格式說明同步十三組件／續播契約。兩次隔離App正常退出，清除一次性AX原始碼／二進位、App副本、HOME與tmp；後端清除fixture、測試二進位及IPC，保留永久回歸與PNG／AX／JSON／建置日誌。沒有改寫使用者收藏、登入、來源配置或持久資料。
- 限制：本輪實播為mpv本地影片及正式App同流程；IINA插件／URL scheme／CLI、JSPlayer非直播、Torrent新保存路徑有整合編譯與對應編碼／owner回歸，但未本輪全實播；受登入限制來源仍需從詳情重選權限。未驗完整VoiceOver、全部Skin／放大字級、實體觸控板、最低macOS／Intel或正式簽署，不代簽既有產品全矩陣。

## 2026-10-13 — 普通頁面鼠標拖動捲動

- 實作：共用 WorkspaceScrollView 加入原生 NSPanGestureRecognizer，只接受最近捲動層的鼠標左鍵事件，按初始窗口位移鎖定方向與 owner。Trends／續看橫向拖动各自處理，縱向拖動沿用推薦分流；推薦與可拖動空白內容上下捲動，邊界由 NSClipView 約束。拖動顯示抓取游標，結束／取消／卸載恢復。click 必須等待 pan 失敗，成功拖動不送出續播／詳情操作；輸入、可選文字、表格原有排序及 split 操作不接管，不增加慣性或排序規則。編排仍由「編輯佈局」按鈕開啟，不修改既有草稿／撤銷／保存實作。
- 問題與修正：正式操作發現 NSPan 在辨識前的 translation／location 未提供可用方向，曾誤分流縱向；改以按下位置與實時屏幕→窗口座標之差處理，同一拖動仍只有一個方向與接收面板。
- 驗證：最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED。用本輪產物的隔離 bundle／HOME 正式 AppDelegate／Workspace，實际鼠標事件與 AX 斷言通過 Trends 橫拖、Trends 縱拖分流、續看橫拖、推薦縱拖；其他方向 scrollbar 不漂移，所有拖動後首頁未跳詳情且未启动播放器。放開後單擊續看實際開啟 mpv，參數 start=45，後續真 IPC time-pos=85.416667；雙擊 Trends 實際開啟作品詳情。按「編輯佈局」看到原生編排樹、草稿及保存按鈕，取消編輯，未保存任何編排。
- 證據／清理：.build/mouse-drag/ 保存 drag-final.log、dragged-home.png、click-resume.log／click-resume-ipc.json、double-detail.log／PNG、editor-proof.log／layout-editor.png，建置為 .build/mouse-drag-build.log。六筆續看樣本為隔離測試前置資料，只用來形成橫向溢出，不宣稱它們由真實播放建立；點擊後的 mpv 與 IPC 為真實播放。隔離 App、樣本播放器與臨時工具／App 副本／HOME／媒體均結案清除，未改使用者資料。
- 限制：未重驗所有設定文字選取、收藏表格拖排、最低 macOS／Intel、全部 Skin／VoiceOver、實體觸控板、IINA／JSPlayer／Torrent 或遠端實播；未新增來源能力或普通瀏覽卡片排序。

## 2026-10-13 — 空白區域拖動接收範圍修正

- 根因：原生 pan 已收到面板空白事件，但命中內層 scroll 以外的標題／邊距時，選到固定高度的首頁外層；外層没有內容溢出，canScroll 拒絕啟動拖動。原先驗證聚焦卡片區，沒有覆蓋這些空白。沒有自行設定啟動距離／長按時間；辨識門檻由 AppKit pan 提供，方向則按初始窗口位移主軸固定。
- 修正：服務面板 root 改用弱引用 scrollOwner 的 WorkspaceDragRegionView，普通非互動空白以所屬面板決定 dragSource；已有內層命中仍按最近 scroll 處理，输入／可選文字／按鈕／表格／split 排除維持。首頁外層加上推薦垂直分流，跨分區間隙可捲推薦；不改卡片排序或編排入口，不取消正常點擊／拖動區分。
- 驗證：Debug arm64 無正式簽署建置 BUILD SUCCEEDED。使用本輪來源產物隔離 bundle／HOME，正式 AppDelegate／Workspace；實際左鍵拖動＋AX 斷言通過 Trends 標題旁空白橫拖、面板左側邊距縱拖、兩分區間隙縱拖、推薦標題旁空白縱拖；另一方向 scrollbar 不變。普通點擊同一空白不捲動且仍在首頁，實際截圖有效。續看無紀錄時 scroll 被收起，驗證工具調整為實際可見三區，不以不存在的第四個 scroll 判為產品故障。證據 .build/blank-drag/proof.log、blank-drag.png 及 .build/blank-drag-build.log。
- 文件／清理：README、前端契約同步；隔離 App 正常退出，清除一次性工具／二進位、App 副本與隔離 HOME。未修改使用者配置或資料。
- 限制：本輪驗證首頁非互動空白；未重驗續播實播、完整編排、所有頁面／Skin／字級、VoiceOver／最低 macOS／Intel。不宣稱已調低原生啟動距離或完成實體鼠標延遲量測。

## 2026-10-13 — 主頁三區共同交互與整頁捲動

- 實作：WorkspaceRenderer 移除首頁固定視窗高度／推薦內層 owner 分流，Trends、繼續觀看與推薦共用一個縱向交互容器；前兩行隨內容一起捲走。推薦網格直接納入共同文件，Trends／續看保留各自的橫向卡片。既有 Layout／Skin 組件身份、獨立編排及自訂佈局保留，不改播放歷史或推薦資料 owner。
- 尺寸／生命週期：主頁三區改用原生 NSCollectionViewFlowLayout，自適應欄數、列高與密度；資料／寬度變動以合併的主線更新調整共同文件高度。正式切頁驗證找出舊 compositional layout 在零尺寸重掛時持續解算及重複面板重設問題；改用 flow 並讓模式重設冪等，移除曾嘗試的佈局暫停／恢復 workaround。共同縱向位置保存在推薦實例的既有私有狀態，重掛暫態不覆寫保存位置，搜尋返回恢復原位置。
- 建置／正式操作：最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED，日誌 .build/shared-home-build-final.log。使用最終來源的隔離 bundle／HOME／CFFIXED_USER_HOME，走正式 AppDelegate／Workspace；實際事件與 AX 斷言 PASS：1280 寬滾輪令三區同移 420 pt、面板邊距縱拖同移 140 pt、分區間隙同移 180 pt、Trends 橫拖不改三區縱向位置、推薦卡片縱拖三區同移且不誤開詳情、960 寬前兩行可捲出畫面、搜尋→發現返回保存原共同位置。正常雙擊開啟真 Bangumi 作品詳情，作品 metadata 及選集區實際載入。
- 證據／文件：.build/shared-home/proof.log、verified-*.ax.txt、verified-feed.png、verified-960.png、verified-return.png、verified-detail.png；已檢視寬窄正式畫面。README、PROJECT、FRONTEND_REFACTOR_PLAN 同步共同捲動契約。清理本輪一次性工具／App 副本與隔離資料，保留建置日誌及交互證據；不清除既有使用者收藏、登入、來源配置或播放歷史。
- 限制：續看驗證為真實空歷史狀態；本輪未重驗有紀錄的續播實播、全部自訂 Layout／Skin／字級、VoiceOver、實體觸控板、最低 macOS／Intel 或正式簽署。不將 UI 捲動驗證擴大為播放器全矩陣驗收。

## 2026-10-13 — BT 搜尋整合播放來源窗口

- 實作：WorkspaceDetailController 的來源與播放窗口加入線上／BT 分頁，帶入作品名且允許改查詢；全域 magnet 與 Torrent 檔案選單導向此窗口。WorkspaceTorrentController 重用原精確選檔、上傳同意、DownloadService 及 Processes，增加明選搜尋結果、取消、遠端種子有界下載與小窗縱向捲動。切換來源類型取消線上待提交自動播放；換集／關窗釋放未提交 BT 工作，不停止已提交播放／下載。torrent.import 組件保留供自訂 Layout 使用。
- 搜尋：TorrentSearchService 每次讀 bt1.json 的 rss/version1 searchConfig.searchUrl，安全編碼一般 keyword 與 JSON filter；解析 magnet／HTTP torrent enclosure、magnet link 與 nyaa infoHash。真網發現 Garden enclosure 實際是 magnet，已修正並保留回歸；不把 HTML 詳情頁當種子、不換固定搜尋網址，不繞過 403。匿名請求、回應大小／status 限制、XML DTD／外部實體拒絕、來源失敗隔離及取消傳遞。
- 建置／回歸：最終 arm64 Debug CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED（.build/bt-playback/build-verified.log）；bash Tests/run-torrent-search.sh PASS，覆蓋 URL／JSON escaping、Garden magnet enclosure、RSS／HTML／entity 邊界、大小、部分／全部失敗、重新讀訂閱與取消。既有 run-w11-torrent.sh 通過三次 4,194,427-byte peer SHA-256 一致與取消／重啟／close 邊界；原生核心未改。
- 正式 App：本輪來源產物的隔離 Bundle ID／HOME／CFFIXED_USER_HOME，正式 AppDelegate／Workspace，非 host。Bangumi 作品選集→BT 分頁自動帶入作品名、640 寬及 460×360 可捲；最終修正後 App 搜尋 Bocchi 返回 AnimeGarden 100 筆，nyaa.land HTTP403 如實並列；結果預設無選取，明選第三項才啟用 metadata，未匯入公開作品或啟動其 P2P。搜尋取消與分頁重建驗證通過。
- 真實播放：自製 90 秒測試圖影片與非影片 decoy，用 loopback seed／magnet 匯入，首次 P2P 同意可取消後重新確認，metadata 無預選；選 decoy 拒絕播放，選 file index 1 的 payload.mkv 後 mpv 顯示動態測試圖，App 收到播放器已載入狀態；停止按鈕後顯示已停止／授權撤銷、邊下邊播重新啟用。全域 magnet 入口進同一 BT 播放窗口亦已操作。
- 證據：.build/bt-playback/ 的 final-results.ax.txt、selected-settled.ax.txt／png、small.png、metadata.ax.txt、nonvideo.ax.txt、loaded.ax.txt／played.png、stopped-settled.ax.txt、search-cancelled.ax.txt、direct.ax.txt；主線對關鍵 AX 狀態逐項斷言 PASS，已檢視真實畫面。README／PROJECT／前端契約同步。關閉隔離 App／peer、清除一次性工具／素材／App 副本與隔離資料，保留去敏證據及建置日誌；未改使用者資料。
- 限制：nyaa.land 當次 HTTP403，未繞過；未重驗 IINA、最低 macOS／Intel、正式簽署、完整下載／多播放器矩陣及 BT 自動作品集數映射。公開 RSS 只查詢 metadata，不宣稱其全部資源可下載或播放；HTTP torrent enclosure 的下載分支尚未正式 UI 真網驗證。本輪 mpv 為自製素材實播，MT3 全矩陣仍未簽收。

## 2026-10-14 — 修正磁力 metadata 被失效 tracker 阻塞

- 根因：AnimeGarden 公開搜尋樣本保留 22 個 tracker；libtorrent 將 magnet tracker 分配到不同 tier，預設逐 tier 等候。原生診斷顯示前置 UDP tracker 10 秒逾時、下一 HTTP tracker 累計約 40 秒才失敗，後面的可用 tracker 尚未被嘗試便耗盡 App 的 45 秒期限；同次 DHT bootstrap 亦未成功，不把問題歸因於 RSS 遺漏 tracker 或 metadata extension 未載入。
- 修正：Native/src/TorrentBridge.cpp 的 tb_add_magnet 僅在公開網路 session 啟用 announce_to_all_tiers。同時聯絡磁力連結已提供的 tiers；不添加外部 tracker、不改搜尋訂閱、不延長 metadata 等候，不變更本機 .torrent 匯入或非公開 session。README／PROJECT 同步此契約。
- 前後對照：原設定的公開樣本在 60 秒內沒有 peer；只變更 tier 排程的原生診斷約 11 秒取得 metadata。重建後實際 App dylib 的搜尋→TorrentSession 匯入成功取得 29 檔 metadata，沒有選取或下載影片內容。
- 正式 App：本次產物的隔離 bundle／HOME／CFFIXED_USER_HOME，正式 AppDelegate／Workspace。搜尋「葬送」得到 AnimeGarden 100 項，nyaa.land HTTP403 原樣顯示；以真實鍵盤選取 H-Enc 第二季結果後匯入，視窗顯示 Public／29 檔／28.19 GB 及檔案清單。未預選檔案，下載／邊下邊播仍 disabled。過程曾受螢幕鎖定阻擋，使用者解鎖後已完成 AX 與截圖驗收。
- 建置／回歸：arm64 Debug CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED；Tests/run-w11-torrent.sh 通過三次 4,194,427-byte SHA-256 一致與取消／重加／close 邊界。證據位於 .build/metadata-fix/ 的 build.log、probe.log、network.log、tiers.log、fixed-probe.log、core-regression.log、public-import.ax、public-metadata.png。公開網路結果不納入依賴外部 swarm 的永久測試。
- 限制／清理：另一筆千夏第二季合集在正式窗口仍回報無 peer，不宣稱所有資源可取得 metadata；未重測使用者已確認的 .torrent 下載，也未重驗完整下載／播放器矩陣、Intel 或最低系統版本。關閉隔離 App、清理本輪診斷工具／App 副本／隔離資料與無關桌面截圖，保留診斷證據；未改使用者下載任務或媒體檔案。

## 2026-10-14 — 詳情快速下載與多集批次提交

- 詳情新增「快速下載…」獨立窗口及在線／BT 分頁；不必先選一集或開始播放。新增 WorkspaceQuickDownloadController，既有 WorkspaceTorrentController 加入影片核取方塊、全選／清除與批次下載，單列播放選擇保留且與下載勾選分離；快速下載頁隱藏播放控制。工程已註冊新控制器，README／PROJECT／前端規劃同步契約。
- 在線逐集保留精確來源身份，以獨立尋源 owner 避免候選互相失效；明選來源並通過既有下載能力與品質／線路解析才可提交。BT 先取得共享下載 root，再為各明選影片建立獨立任務；成功項目在本次窗口排除重試，失敗／未就緒項目保留。取消／離頁／關窗停止未提交工作，不撤回 DownloadService 已接收任務。
- 正式 AppDelegate／Workspace 在隔離 bundle、HOME、CFFIXED_USER_HOME 驗證：Bangumi「孤独摇滚！」詳情未選單集也能開啟快速下載，列出 16 個集數項目；初始無勾選，全選／清除／只勾前兩集有效。直接 XiFan Anime 頁列出 25 集精確目錄，明選第 01／02 集來源後兩列就緒，一次提交兩筆且成功列 disabled；關窗後兩筆仍完成。成品分別 288,459,385／319,482,623 bytes，ffprobe 確認各有 H.264／AAC、獨立檔名及時長。未宣稱所有番劇尋源候選皆可下載。
- BT 實測使用自製三檔 loopback magnet：非媒體 decoy 不可勾，兩個影片起初不預選，勾選後一次建立兩筆、成功後排除重試。關窗後皆 completed；803,462／968,423 bytes 與 seed 逐 byte 相同，SHA-256 存於 bt-sha256.txt。沒有為 BT 實測下載公開 swarm 影片。公開搜尋的 nyaa.land HTTP403 原樣顯示。
- arm64 Debug CODE_SIGNING_ALLOWED=NO 建置通過；Tests/run-torrent-search.sh 通過。Tests/run-w11-downloads.sh 本次未通過：forced-kill／relaunch 階段回報 torrentNoPeers／process restart did not finish persisted task（exit 133）；不宣稱完整恢復回歸通過。最終建置另重開確認內容 760×680 預設窗口、多集勾選與 BT 切換；最低 macOS／Intel／正式簽署未驗證。
- 證據位於 .build/quick-download/：build-verified.log、final-online.png／final-bt.png、final-window-size.txt、online-resolved.ax／online-submitted.ax、bt-checked.ax／bt-submitted.ax、tasks-final.png、completed-records.json、completed-media.json、bt-sha256.txt。結束隔離 App／seed，清除本輪程式、App 副本、隔離資料與測試下載媒體，保留上述證據；未修改使用者原有下載任務。

## 2026-10-14 — 詳情未更新集數合併與在線下載先選源

- 詳情將空白、未知／標題未知及 Unknown 集名合併成單一不可選取的「更新中」，已知集名與穩定身份保留；隱藏項目不改變原始陣列索引。刷新後選集失效會清除未提交播放來源，不自動換集。
- 在線批量下載改為先尋找／明選作品來源，再載入該來源精確集數或分 P 供勾選；移除逐集選源及開窗時建立本機 Episode 的舊流程。換源撤銷未提交目錄、勾選與解析，窗口級成功身份保留，已提交傳輸仍由 DownloadService 管理；BT 流程未修改。README／PROJECT／前端規劃同步契約。
- arm64 Debug 最終建置通過；Tests/run-workspace-detail-episodes.sh 通過，涵蓋未知標記、已知名稱、隱藏間隔、混合類型、本機 offset、重排與選集撤回。
- 隔離 bundle／HOME 啟動正式 AppDelegate／Workspace：Bangumi 614640 的 12 集顯示 3 個已知集名及單一停用「更新中」；513878 全部 10 個未知集名只顯示一個停用佔位，播放不可用。XiFan 作品來源未選時無集數，明選後列出 25 集且全未勾選；勾前兩集可解析到就緒，清空來源後集數清除且提交停用，重選來源不保留勾選。BT 分頁帶入作品搜尋，結果不預選，HTTP 403 如實呈現。
- 證據位於 .build/source-first/：build-final.log、detail-regression-final.log、detail.ax/png、all-updating.ax/png、initial-download.ax、catalog.ax、reset.ax（含兩集就緒）、current.ax、reselected.ax、online.png、bt.ax/png。本輪未實際提交媒體下載、未驗證多站搜尋全矩陣／部分提交失敗／跨源成功身份排重／最低系統／Intel；不沿用前輪下載完成證據冒充本輪驗證。結束隔離 App 並移除暫時 AX 程式、App 副本與隔離資料，保留驗證證據；未改使用者下載任務。

## 2026-10-14 — 更新中佔位位置與下載任務操作修正

- WorkspaceDetailController 將未更新佔位併入各集數分組的原網格，接在該組最後已更新集數之後；不再將獨立網格加到選集底部。全未更新組保留單一停用佔位，已知集數身份及原始映射索引不變。
- WorkspaceServicePanelController 將暫停／繼續／取消任務置於獨立操作列，提示先選任務並顯示所選標題；完成檔與刪除命令分列。相同任務集合的進度事件僅刷新列內容，保留原生選取；任務移除時清除失效選取，避免誤操作其他任務。沿用 DownloadService allowedOperations，不新增傳輸狀態或來源能力。
- arm64 Debug 合併建置通過，Tests/run-workspace-detail-episodes.sh 通過。隔離 bundle／HOME 的正式 AppDelegate／Workspace 驗證：614640 的第 3 集與停用「更新中」同一排、相鄰；選取第 3 集仍帶入精確集名。513878 全未更新僅顯示停用佔位，播放所選集數停用。證據：.build/episode-download-fix/build-final.log、detail-regression.log、episodes.ax/png、selected.ax、all-updating-final.ax/png。
- 下載正式 App 實測：原生鼠標選取任務並按繼續／暫停，暫停後 5,390,282 bytes 相隔兩秒不變，再繼續增至 9,175,040 bytes；選取及操作狀態保持。取消鄰居任務不影響首項傳輸；完成檔刪除後保留記錄、停用檔案入口，刪記錄後選取清空及操作停用。Tests/run-w6-downloads.sh 通過真實 Range／HLS、暫停／恢復、取消與程序恢復。證據：.build/episode-download-fix/download-service-smoke.log、download-paused-records.json、download-paused-stable.json、download-resumed-records.json 及 download-*.ax/png。
- 最後將任務身份比較改為 zip/allSatisfy，避免建立兩份 ID 陣列；最終增量建置及選集回歸通過（build-delivery.log），原生下載實測在此等價比較最佳化前執行。README 同步選集佔位與下載操作說明。未另外驗證 Torrent 暫停／繼續、播放器實播、Finder 定位、最低 macOS、Intel 或正式簽署。
- 隔離 App 已退出；清除暫時操作工具、App 副本及隔離下載／資料，只保留上述證據，未更動使用者原有下載任務。

## 2026-10-14 — 繼續觀看番劇封面快取重用

- 續看原本已透過 WorkspaceMediaThumbnail 共用 SDWebImage 記憶體／磁碟快取；本輪在 WorkspaceResumeCardView 保留縮圖，同 URL、預覽模式、Skin owner 與組件身份的重新配置不再移除及重建圖片視圖。封面網址或呈現上下文改變才替換，防止卡片重用顯示舊封面；不建立第二套磁碟快取或改變觀看歷史格式。
- arm64 Debug 建置通過。隔離 bundle／HOME 啟動正式 AppDelegate／Workspace，以本地 HTTP 提供公開番劇封面、隔離播放歷史顯示「孤獨搖滾！」續看卡片；HTTP 記錄確認首次成功載入。退出 App 並停止封面伺服器，curl 確認來源不可連線後重啟，卡片仍顯示同一封面及 1:11／23:40 進度，驗證磁碟快取跨程序重用。證據：.build/resume-cover/build.log、http.log、online.png、offline.png。
- README 補充快取重用與清理邊界。未驗證最低 macOS／Intel／長期過期淘汰或正式簽署；測試歷史為隔離 fixture，不宣稱新增實播證據。退出測試 App、停止本地服務並移除 seed 工具、App 副本、隔離資料及測試封面，未觸碰使用者歷史或快取。

## 2026-10-15 — 下載封面預抓、按番劇分組與已下載集數標記

- DownloadService 接收並持久保存公開封面 URL、Bangumi ID、精確 episodeKey；服務持有共用 SDWebImage 磁碟快取工作，關閉選集／下載窗口不取消已提交任務的封面。下載列表重用縮圖，顯示集名及已下載／完成檔已移除狀態；不因每次進度事件掃描完成檔。
- 新番劇任務以 Bangumi ID、本機作品 ID 或來源作品身份建立穩定子目錄；同名異番隔離、普通影片不分組，舊任務及完成檔不搬移。名稱按 UTF-8 長度清理，子目錄與發布使用 directory fd／O_NOFOLLOW／exclusive rename；根路徑 realpath 正規化以支援 macOS /var alias。
- 詳情選集／來源目錄、快速下載及 Torrent 檔案列共用完成檔快照；只依精確身份或已確認映射，不以集名／順序猜測。事件與 App 回前景刷新，實體檔不存在即移除標記；長集名的「已下載」置於前綴，避免尾端截斷。快速下載禁止重新勾選已完成的在線集數。
- arm64 Debug 最終建置及 CacheServiceRegression、WorkspaceDetailEpisodeRegression 通過。真實 loopback HTTP 下載兩個測試影片，逐 byte 核對完成檔、同番資料夾、任務 metadata；未建立任何圖片視圖前，封面已寫入磁碟。HTTP 記錄僅一筆封面 GET 與兩筆影片 GET。證據：.build/download-library/build-final.log、cache-regression.log、detail-regression.log、smoke.log、http.log、completed.json。
- 隔離 bundle／HOME 的正式 AppDelegate／Workspace 驗證：下載頁兩列封面與各集完成標記；封面來源停止後冷啟動仍顯示封面；詳情第1／2集標記、第3集無標記。原生刪除第1集完成檔並重開詳情，只移除第1集標記；最終版本冷啟動保持狀態，長第2集名稱仍看得到前綴。外部刪除第2集影片後回到 App，第二集標記自動取消。證據：downloads.ax/png、deleted-download.ax、deleted-detail.ax、offline-restart.ax/png、final-detail.ax/png、external-delete.ax/png。
- 最終普通影片分類邊界修正後增量建置通過（build-delivery.log）；最新版 W6 真實 HTTP／HLS、分組與身份隔離、程序重啟、外部／主動刪檔、symlink 拒絕及明確一般影片不分組全通過（.build/download-grouping-w6.log）。DownloadServiceStateRegression 舊 optional 欄位、完成快照與刪檔通過（.build/download-grouping-state.log）。正式 UI smoke 在此僅影響一般影片分組判定的修正之前執行。
- README 同步行為與舊資料邊界。未另行驗證公開站點媒體下載、BT 實際完成檔標記畫面、最低 macOS、Intel 或正式簽署；本輪影片為隔離 loopback fixture，不宣稱公開來源實播。
- 已退出隔離 App、停止 HTTP 服務，移除暫時工具、App 副本與隔離資料，只保留 logs／截圖／AX／完成記錄證據；未更動使用者原有任務、影片或快取。

## 2026-10-15 — 首頁同步本地封面、集數與最新觀看進度

- PlaybackHistoryStore 新增首頁投影：以完成檔與來源精確身份關聯下載 metadata，補齊舊本地記錄的作品、集數與封面；按 Bangumi／作品／來源作品身份僅顯示最近觀看的一集，不以檔名猜測合併。各集原始秒數及本地續播目標保持不變，隱藏項目的進度不刪除。
- Processes 從下載頁開啟完成檔時帶入作品、集名及封面；首頁訂閱下載與播放歷史變更。續看資料更新使用獨立 task，避免進度通知取消正在進行的播放命令；卸載面板取消觀察與更新。README 已補充行為。
- arm64 Debug 最終建置通過；run-dependency-regression.sh --unit 通過，新增舊本地 metadata 補齊、同作品只顯示最新集、回看較早集按時間勝出及隱藏集秒數隔離回歸。
- 以隔離 CFFIXED_USER_HOME 啟動本次建置的正式 AppDelegate／Workspace，兩集本地歷史呈現為一張「本地續看驗證／第2集／0:42 / 2:00」卡片，本地 HTTP 橙色封面成功顯示。證據：.build/continue-local-build-final.log、continue-local-ui.png、continue-local-ui.ax。
- 既有真實 mpv smoke 通過：IPC 觀察 39.333333 秒，保存後由新 AppServices owner 續播至 41.416667 秒。正式視窗的點擊未取得新的播放進度，故不宣稱本輪正式 UI 點擊實播通過；UI 顯示與 mpv 服務鏈證據分開記錄。App 日誌仍有既有 collection layout 高度警告，本輪未處理。
- 已關閉本輪隔離 App 與封面服務、移除隔離 fixture；未修改使用者原有行程或歷史。未驗證公開站點、最低 macOS、Intel 或正式簽署。

## 2026-10-15 — 推薦寬度僅隨頁面尺寸重算

- WorkspaceServicePanelController 快取推薦網格已套用寬度及欄數；updateDiscoveryGeometry 在可用寬度不變時不再讀取密度、計算欄數或重設卡片尺寸，分頁與內容更新仍依現有尺寸更新總高度。presentationSettingsDidChange 明確清除快取以套用使用者手動密度變更；零寬度切頁暫態保留快取。PROJECT 同步此契約，未改推薦來源、載入策略或共同捲動 owner。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。一次性 AppKit smoke 直接擷取正式 updateDiscoveryGeometry／feedColumns 方法，驗證同寬度 20 次更新及新增項目不重新讀取尺寸設定；資料增加仍擴高、寬度改變重算、零寬度後重掛不重算、手動密度失效後更新皆 PASS。沒有新增只測程式接線的永久測試。
- 隔離 Bundle ID／HOME／CFFIXED_USER_HOME 的本次正式 AppDelegate／Workspace 實測：1280 寬推薦卡片 131 pt，960 寬改為 148 pt；按載入更多，72→96 筆仍為 148 pt。原生 AX 捲軸令推薦起點由 y=459→-425.5，卡片寬度不變；已檢視寬窄與捲動後的真實視窗截圖。一般 CG 滾輪未令當次桌面上的 App 移動，未將其算作通過。
- 證據位於 .build/feed-width/：build-final.log、geometry-smoke.log、ui-evidence.json、wide／narrow／paged／scrolled.ax.txt、wide／narrow／scrolled.png。關閉隔離 App 並移除一次性程式／二進位、App 副本及隔離資料；未修改使用者資料。本輪未驗證最低 macOS／Intel、全部自訂 Layout／Skin 或實體滑鼠／觸控板。

## 2026-10-15 — 推薦欄右側留白

- 僅將 discovery.feed 網格的右側留白由 10 pt 調為 15 pt，左側保持 10 pt；共同主頁與獨立推薦面板都套用，Trends／繼續觀看不變。macOS 使用邏輯 pt，不按 Retina 實體像素換算。
- Debug arm64 無正式簽署建置 BUILD SUCCEEDED；一次性 AppKit 約束煙霧驗證在 756／1076 pt 容器均得到左側 10、右側 15 pt。未重新操作正式 App 視窗或截圖，不宣稱本輪正式 UI 驗收。已移除一次性煙霧腳本，未修改使用者資料。

## 2026-10-15 — 推薦留白改為整列換行邊界

- 依使用者澄清，撤回推薦容器寬度縮減，改用 discovery.feed 的 flow sectionInset.right=15；計算欄數及卡寬時只從整列可用寬度扣除一次。卡片內距不變、最小卡間距仍 4 pt，其他欄不變。
- Debug arm64 建置 BUILD SUCCEEDED。原生 NSCollectionViewFlowLayout 煙霧實際檢查換行與卡片 frames：756／1076 pt 寬分別 5／8 欄，列尾都留 15 pt，卡間距為 4／約 4.143 pt（flow 分配取整餘量），沒有逐卡片增加 15 pt。初版煙霧未掛 scroll 導致換行斷言失敗，補齊原生捲動視口後通過；未重做正式 App 視窗截圖。一次性腳本已清除。

## 2026-10-15 — 清理暫存與一次性驗證產物

- 依使用者選定範圍，移除 `.build/`（約 8.05 GB）、工程及 HuyaKit 下三處 `xcuserdata/`、三個 `.DS_Store`；保留正式 Tests、有效文件、原始碼、共用工程設定、鎖檔、授權及已安裝網頁／外掛依賴。未操作專案外的使用者資料。
- 歷史記錄中 `.build/` 的日誌、截圖及驗證產物已隨本次清理移除；既有記錄保留為當時結果，不表示這些證據檔目前仍存在。下次建置將重新下載及編譯原生依賴。
- 清理後確認七個目標路徑均不存在；排除清理目標及 node_modules／Git 的 353 個保留檔案 SHA-256 全部一致。`plutil -lint IINA-ANI.xcodeproj/project.pbxproj` 通過。本次未改產品行為，未重新建置、執行正式測試或啟動 App。

## 2026-10-15 — 修正 Layout Script 控制器重複編譯

- 工程同時編譯 Workspace 與 Utils 下同名的 WorkspaceLayoutScriptController.swift；`cmp` 確認兩份內容完全一致。保留 Workspace 原檔，移除 Utils 副本及其 PBXBuildFile、PBXFileReference、群組與 Sources 引用；未變更控制器行為。
- 使用使用者的 DerivedData 路徑執行 Debug／CODE_SIGNING_ALLOWED=NO 實際建置，已越過建置圖檢查，未再出現 Multiple commands produce。建置在原生依賴下載階段受阻：curl (35)，連線 www.openssl.org:443 發生 LibreSSL SSL_ERROR_SYSCALL；不宣稱完整建置通過，未啟動 App。初次嘗試的 -dry-run 被目前 Xcode 拒絕，後改為實際 build。
- 全庫搜尋已無 Utils 舊路徑及已刪除工程 ID 的引用。驗證建置重新建立部分 .build 暫存，保留供後續依賴下載／建置續用。

## 2026-10-15 — 修正推薦載入狀態造成的版面抽動

- 原因：推薦狀態列原本插在網格上方，載入時顯示、完成時隱藏；原生 AppKit 約束煙霧重現卡片頂端移動 36 pt。WorkspaceServicePanelController 將推薦狀態改置網格後的頁尾，保留基本 32 pt，高度仍容許較長錯誤訊息；共同捲動／獨立面板互換時保留內容順序。未改卡寬、資料來源或載入策略。
- 驗證：本輪 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。一次性原生約束煙霧驗證獨立面板及共同文件模型，載入／完成前後卡片位置及高度一致，頂端偏移 0 pt。
- 正式 App：以本輪產物隔離 Bundle ID／HOME／CFFIXED_USER_HOME，走 AppDelegate／Workspace；AX 操作「載入更多」，實際觀察載入提示出現在網格後，72→96 筆，載入前／載入中／完成後網格起點均為螢幕 y=459 pt，寬度 1076 pt；高度由 1760 增至 2348 pt。已檢視正式視窗截圖，證據保留於 `.build/feed-stability/`。
- 清理／限制：退出隔離 App，清除一次性工具、App 副本與隔離資料，未修改使用者資料。未驗全部 Skin／字級、實體觸控板、最低 macOS 或 Intel；不將本次推薦分頁證據擴大為所有刷新／捲動路徑驗收。

## 2026-10-15 — 修正推薦網格載入時左右推動

- 使用者補充仍有水平位移，上一輪狀態頁尾修正不代表此問題已解決。正式 App AX 追蹤及原生嵌套 collection 煙霧定位：collection 寬度 756 pt、卡寬 145 pt 不變，Flow Layout 在共同捲動／重載時卻將第二至第五欄從相對 x=149／298／447／596 推到 154／308／462／616，最多移動 20 pt；外層 clip 比 collection 寬 20 pt。單純保留卡片寬度不足以固定欄位座標。
- 新增 WorkspaceFeedGridLayout，依 collection 自身寬度決定欄數、卡寬、座標與總高度；只為查詢範圍建立卡片 attributes，維持 15 pt 整列右留白、4 pt 最小間距及既有密度。移除 controller 的重複寬度／欄數快取與 Flow 專用推薦設定；Trends、續看和其他組件維持原 layout。工程 Sources 同步註冊新檔。
- 驗證：最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED；新增 `Tests/run-workspace-feed-grid.sh` 通過共同捲動／追加分頁保持舊卡片位置、尾列高度、可視範圍／無限查詢、縮放欄數、密度及空資料；`Tests/run-workspace-layout.sh` 通過。測試初版在建立 layout 前註冊 cell 導致 AppKit dequeue 例外，調整 native harness 註冊順序後通過，未以吞例外處理。
- 正式 App：本輪產物隔離 Bundle ID／HOME／CFFIXED_USER_HOME、正式 AppDelegate／Workspace。960 寬手動載入的 326 次取樣保持水平座標；1280 寬共同縱向捲軸觸發自動載入，266 次取樣卡片均保持既定八欄，內容高度 4700→5876 pt；縮至 960 後自動載入，237 次取樣保持五欄，內容高度 9404→11364 pt。已檢視寬窄深捲動截圖。AX 觀察工具已改為選取共同頁面的縱向捲軸，排除誤操作 Trends 橫軸；重載重用期間不將 AX 元素引用當成固定作品身份，而核對實際欄位座標。
- 證據保留 `.build/feed-horizontal/` 的修正前追蹤、fixed-narrow／fixed-wide／fixed-narrow-auto 日誌及 PNG；退出隔離 App，清除一次性診斷程式／App 副本／隔離資料，不更動使用者資料。未驗全部 Skin／字級、自訂佈局完整矩陣、最低 macOS／Intel、播放或下載。

## 2026-10-15 — 詳情人物圖片與關聯封面

- WorkspaceDetailController 的人物介紹接入 character.coverURL，關聯分組網格接入 subject.coverURL；重用 WorkspaceMediaThumbnail 的非同步載入、SDWebImage 快取及缺圖／失敗提示，不新增圖片服務。人物圖片與完整介紹並排；關聯保留應用內開啟按鈕、完整標題 tooltip，長標題截斷避免撐破欄寬。選集網格維持原行高。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED；Tests/run-workspace-detail-episodes.sh 通過。正式 AppDelegate／Workspace 使用隔離 Bundle ID／HOME／CFFIXED_USER_HOME，實際開啟 Bangumi 328609，確認人物圖片、介紹及分組關聯封面；重新啟動最終產物後確認快取圖片顯示，點擊關聯「女孩的钓鱼慢活」成功進入該作品詳情。UI 煙霧發現的人物卡片未展寬、關聯長標題撐寬已修正並以最終畫面確認。
- 已檢視 `.build/detail-images/characters-portraits.png`、`relations-final.png`，AX 證據同目錄；README 同步行為。退出隔離 App 並清除一次性工具、App 副本及隔離資料，保留截圖／AX／日誌，不修改使用者資料。未驗全部 Skin／字級、最低 macOS／Intel，未另行模擬斷網或圖片失效。

## 2026-10-15 — 長簡介收合與原生 HTML 連結

- 詳情作品／人物簡介改用可展開摘要：預設最多 280 個 Swift Character 或六個明確換行的文字行，按「展開全文／收合」切換；完整資料與連結屬性保留，相同作品簡介重繪不重設展開狀態，內容替換重設。這不是按視窗寬度計算的六個視覺行。
- 詳情文字重用既有 SwiftSoup 解析 HTML 段落、換行、實體與 anchor，NSDataDetector 辨識純網址，NSTextField 呈現可選取／可點擊原生連結。僅允許 HTTP／HTTPS 絕對網址；不執行 script／style／iframe／object，不載入 HTML 圖片或外部資源，不使用 WebView／HTML importer。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。一次性原生富文字煙霧驗證 HTML 段落／實體、anchor 的解碼後目的 URL、純網址、拒絕 javascript 連結與腳本內容，全部通過。
- 本輪正式 AppDelegate／Workspace 隔離啟動，Bangumi 328609 的後藤一里簡介預設截短、展開完整文字、再收合皆實際操作；檢視 collapsed／expanded 截圖。作品資訊官方網址顯示原生藍色 AXLink，啟用後 Chrome 前景分頁 URL 為 https://bocchi.rocks/tv/。證據位於 `.build/detail-reading/`；HTML anchor 解析由煙霧覆蓋，正式公開資料頁驗證的是純網址。
- README 已同步。退出隔離 App、移除一次性工具與 App／HOME 副本，保留截圖／AX／日誌；不修改原有作品資料。未驗全部 Skin／字級、最低 macOS／Intel 或任意 HTML 排版；不宣稱完整網頁渲染。

## 2026-10-15 — 在線／本地同源自動連播

- 新增「設定 → 播放與彈幕 → 同源自動連播」，預設開啟，與解析結果自動開啟獨立。Processes 在匹配媒體的自然 EOF 後才讀取來源目錄並重新解析下一集，保留作品／來源／帳號／線路／品質；精確身份不明、重複身份、跨目錄分組或末集不接續，不跨在線／本地。直播及 Torrent 邊下邊播不自動換項。
- 本地影片／已完成下載／續看共用同資料夾自然排序，排除隱藏檔、子目錄與符號連結；下一檔獨立更新歷史及下載 metadata，只用自己同名 XML。回歸揭露 FileManager 枚舉將 `/var` 正規化為 `/private/var` 導致匹配失敗，已改用同一資料夾的精確檔名比較並保留原 URL 身份。另修正新測試中誤用的 Senfun hostname／路由，未放寬產品來源規則。
- PlayerProgressSession 先完成舊 recorder／釋放 IPC 再通知一次性 EOF；stop／quit／error／換檔不續播，App shutdown 取消並等待待處理連播，各播放 session 獨立。解析／啟播失敗呈現錯誤、不跳集。JSPlayer bridge 為結束／錯誤事件附上 generation，區分下載完成與自然 EOF，關窗／換片取消舊工作；保持現行僅直播來源入口能力，不宣稱新增 JSPlayer 點播支援。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。`Tests/run-dependency-regression.sh --unit` 全通過，含新增在線雙線路 parser fixture、精確身份／來源邊界、末集、重複身份、本地自然排序／XML 隔離與 EOF-only 回歸；`node Tests/Playback/JSPlayerAutoplayRegression.js` 通過自然 EOF、去重、過期事件、pause／seek、載入完成、錯誤／destroy／直播生命週期。
- 真實 mpv 服務鏈使用三個 8 秒影片，實際觀察 `Episode 1 → Episode 2 → Episode 10` 並於末集清除完成歷史；關閉連播、手動 stop、AppServices shutdown 均未開下一集。此服務鏈 smoke 在最後的 `/var` 別名修正前執行；別名修正由最終回歸及以下正式 App 播放覆蓋。
- 最終建置產物以隔離 Bundle ID／HOME 啟動正式 AppDelegate／Workspace，從首頁續看卡片實際點擊啟播 mpv，歷史取樣記錄三集各自秒數，約 23.95 秒後末集完成且歷史為空；設定畫面實際操作連播核取方塊 `1 → 0 → 1` 並檢視截圖。證據：`.build/autoplay/build-final.log`、`formal-playback.json`、`autoplay-settings.ax/png`、`settings-toggle.txt`。初次 UI helper 未設定原生 click count，未觸發播放；修正 helper 後以最終產物重做通過，未修改產品點擊邏輯。
- README 同步使用方式及邊界。已停止隔離 App、移除一次性工具／影片／App 副本與測試資料，保留上述證據；未更動使用者原有資料。公開在線站點實際跨集、IINA／彈幕實播、多視窗真播放器矩陣、最低 macOS／Intel 及正式簽署未驗證；在線證據為真目錄解析 fixture 與選集回歸，不冒充公開站點實播。

## 2026-10-15 — 完季清理續看與連載保護

- 依使用者補充，將「播到來源最後一集」與「整季已更新完」分開：WorkLibrary 僅接受精確關聯作品的 Bangumi 動畫資料、明確總集數、完整唯一主線集數與集名、全部已過的播出日期及匹配來源／下載身份。未播完的連載、當日／未來播出、總集數或日期不明、目錄缺集、重複／衝突關聯均不清理。第二季絕對 sort 搭配相對 ep 可辨認；本地混合資料夾只清理該作品已精確映射的主線影片記錄。
- Processes 在末集自然 EOF 後清理確認完成的同季續看記錄，與連播開關獨立；不刪下載、影片或收藏。缺少完結證據時保留真實 EOF 秒數並持久化 awaitingUpdates，首頁顯示「此集已看完 · 保留追更」；點選由 0 秒重播，新集由詳情選播。關閉連播時中間集 EOF 亦保留；解析／啟播失敗不丟失當前卡片。以完成時間邊界保護較新的多視窗進度，重播會清除等待旗標。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功，`Tests/run-dependency-regression.sh --unit` 通過，涵蓋完結／連載證據、來源分組／身份、EOF 持久化、重播、非末集關閉連播、舊 EOF 與新進度競態。`Tests/run-work-library.sh` 的遷移與作品關聯回歸、`node Tests/Playback/JSPlayerAutoplayRegression.js` 的事件生命週期回歸亦通過。
- 最終正式 AppDelegate／Workspace 搭配真 mpv，以隔離 Bundle ID／HOME、真實 Core Data／下載映射和四個 8 秒影片驗證：已完結兩集季末集 EOF 清除兩筆；三集連載僅有前兩集、第三集未來播出時保留兩筆及 EOF 卡片。冷重啟後仍只顯示連載；點擊已看完卡片實際進度從 1 秒重新遞增至 7.958 秒並再次保留；全部四個影片檔仍存在。另驗證關閉連播時第 1 集 EOF 保留且不播放第 2 集。
- 中間集初次煙霧發現命令列 `-autoPlayNext NO` 是字串而非 typed Bool，實際仍為預設開啟；這是煙霧設定錯誤。改用隔離 domain 的 `defaults write … -bool false`、移除字串 override 後，上述末集、非末集與重播情境皆以最終產物重做通過，未為煙霧修改產品偏好邏輯。
- 證據：`.build/season-completion/build-final.log`、`final-runtime.json`、`intermediate-eof.json`、`replay-evidence.json`、`final-shelf.ax/png`、`final-restart.ax`；已檢視最終畫面。README 同步判定與保留規則。隔離 App 已退出，臨時工具、媒體、App 副本與 profile 已移除，保留證據；未修改使用者資料。公開在線來源跨集／末集清理、IINA 實播及 Intel／最低 macOS 未驗證；在線完結判定由精確來源 fixture 回歸覆蓋，不冒充公開站點實播。

## 2026-10-15 — Bilibili 關注動態改為 YouTube 式網格

- WorkspaceServicePanelController 將關注動態由橫向封面列切為自適應直向影片網格；專用卡片呈現 16:9 圓角縮圖、右下時長、常駐兩行標題、UP 主、格式化觀看數及多分 P 提示。不更動其他發現卡片、帳號或播放解析；保留選取、雙擊／鍵盤開啟、複製網址及原始頁面操作。
- 分頁觸發改為距離垂直底部 240 pt，請求失敗不因繼續捲動反覆自動重試，保留刷新與較舊影片手動入口。README 同步新呈現方式。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功。啟動本次正式 AppDelegate／Workspace，透過工作區選單打開關注動態，實際載入 20 筆動態；操作刷新、調整視窗並檢視截圖，確認 960×740 為兩欄、1280×820 為三欄，長標題換行、縮圖／時長及分 P 資訊可見。證據：`.build/followed-youtube/minimum.png`、`wide.png`。
- 初次畫面驗證中較舊動態請求出現資料格式錯誤，已有 20 筆影片保留；未更動 Bilibili 解碼，不宣稱遠端歷史分頁成功。未實測播放、複製網址／外部瀏覽器、最低 macOS 或 Intel；未新增永久測試或臨時產品開關。

## 2026-10-15 — Bilibili 普通影片直接播放並保留分 P 頁面

- WorkspaceDetailController 的影片網址／動態入口與 PlayableSelection 入口採 Bilibili 普通影片直接解析並播放，不等待使用者先選分 P。保留詳情與來源播放窗口；依現有目錄解析器驗證的 current 選中指定 P，無 p 時沿用第一 P，保留帳號／品質／線路及番劇流程。已帶 episode 的選擇以該 episode 取得目錄，不回到原 item 的 P。
- 真實煙霧發現第一 P 的正規網址省略 `?p=1`，原始字串比較造成已播放但未選中。改為以 BV 身份與 P 比較選中狀態，第二 P 及其他影片不誤選。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功；`Tests/run-dependency-regression.sh --unit` 全部通過（於最後選中呈現修正前執行），包含目錄重排、BV／av、缺少分 P 與合集精確身份。
- 正式 App 實際從關注動態開啟兩 P 影片，未手選分 P 即啟動 IINA 並顯示真實影片。最終產物以同片 `?p=2` 入口自動提交播放，保留頁面且 AX 顯示「第一 P 未選取／第二 P 已選取」；點選第一 P 後 AX 反轉，IINA 顯示第一 P 真實畫面。證據：`.build/followed-youtube/part2-selected.png`、`direct-play-final.png`。README 同步直接播放與保留頁面規則。
- 未實測搜尋結果入口、公開 av／b23 網路重新導向、番劇或完整播放器／彈幕矩陣；第二 P 僅驗證選中與提交狀態，不將其當作獨立解碼畫面證據。未建立臨時產品開關或修改帳號／播放器偏好。

## 2026-10-15 — 繼續觀看僅呈現番劇

- PlaybackHistoryStore.continuing 在作品去重前只接受明確 anime 分類；下載檔沿用精確檔案映射的來源分類。普通影片與未知分類（包括既有記錄及 EOF 保留項）不出現在續看列，不依站點或檔名猜測番劇；原始歷史與秒數保留、不刪除資料。首頁空態同步番劇範圍，README 補充規則。
- PlaybackHistoryRegression 新增同站番劇／普通影片與番劇檔名但未知分類的混合記錄，驗證續看只保留番劇、冷重讀仍隱藏非番劇且原始三筆進度完整。既有下載 metadata／同作品去重／EOF 續看案例明確配置 anime，保留本地下載來源分類與續播目標不變的驗證。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功，`Tests/run-dependency-regression.sh --unit` 全部通過。啟動本次正式 AppDelegate／Workspace 並打開發現首頁，畫面實際只顯示兩部番劇續看，前輪實播的普通 Bilibili 影片未顯示；截圖已檢視，保存於 `.build/followed-youtube/anime-only-home.png`。
- 本輪未重新實播番劇或驗證所有分類來源／最低 macOS／Intel；分類未知的舊本地影片沒有可對應番劇下載記錄時會隱藏，不自動推斷或改寫分類。

## 2026-10-15 — 可選作品收藏分類與 Bangumi 同步

- 詳情新增「想看、在看、已看、擱置、丟棄」選單；可不設定分類而僅本機收藏，既有收藏可修改分類或重試同步。未修改收藏欄 controller、雙欄版面、排序或篩選。README 已記錄操作及邊界。
- Work payload 向後相容保存分類、待同步旗標與修訂身份；先本機保存再同步，失敗及重啟保留。BangumiService 使用既有帳號傳輸，依官方 API 以 POST 僅提交 type，要求 204，不送評分／評論／標籤／隱私／集數預設值；讀取當前帳號的精確作品記錄，不批次匯入。寫入序列化並防護帳號／關聯／本機修訂變更，遠端讀取不覆蓋待同步修改。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功；`Tests/run-w4-bangumi.sh`、`Tests/run-work-library.sh` 通過，涵蓋類型映射、API 讀寫與失敗、並行／過時回應、舊 payload、SQLite 重開與 pending 保留。最後補充未關聯提示後再次建置 exit 0。
- 本輪產物的隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace，開啟 Bangumi 328609，實際確認五種選項、提交擱置後本機保存與未登入錯誤，收藏頁仍為原作品／連結雙欄。正常退出、冷重啟後從收藏「Open Details」重開，擱置與待同步提示仍在；已檢視正式詳情與收藏頁截圖。AX 初次雙擊未選中收藏列，改用原生 AXSelected 與 Open Details 完成重啟驗證，未修改產品點擊行為。
- 證據 `.build/collection-status/`：build-final.log、choices.ax、saved.ax、restart.ax、collection-detail.png、collection-saved.png、favorites.ax/png。隔離 App 正常退出，已清除一次性 driver、App 副本與隔離 profile；原使用者 App 未關閉。
- 限制：未以真實已授權 Bangumi 帳號寫入遠端記錄；登入後成功同步、權限拒絕及競態以注入傳輸回歸驗證，不冒充真網帳號驗收。未測最低 macOS／Intel、所有 Skin／字級或播放；此功能不包含觀看秒數／逐集進度同步。

## 2026-10-15 — 修正 Bangumi 收藏空回應被誤判為網路錯誤

- 使用者回報 `Response could not be serialized, input data was nil or zero length.`。BangumiService 原本先以 Alamofire 預設規則序列化，再檢查 HTTP 狀態；空 404／401／403 等會提前拋錯，遮住「尚無收藏」或授權／伺服器錯誤。改為傳輸層保留所有 HTTP 狀態的空內容，仍由原本的狀態／預期 204／JSON 解碼檢查判定結果，不把任意空回應視為成功。
- 新增不使用 BangumiService transport closure 的 URLProtocol 回歸，實際走 AccountHTTP／Alamofire。舊 dylib 在空 404 路徑重現完全相同的序列化錯誤；修正後空 404 正常回 nil、空 204 寫入成功、403／500 保留狀態、401 正確將帳號標為過期。前輪注入傳輸回歸未覆蓋這一層，不能當作真實 HTTP 序列化驗證。
- Debug arm64 建置 exit 0，`Tests/run-w4-bangumi.sh` 全通過。另以最終 App dylib 執行無憑證、無寫入的真網 `/v0/me` 讀取，取得 HTTP 401 並完成過期狀態轉換，不再出現空內容序列化錯誤。證據 `.build/collection-status/empty-response-build.log`、`http-smoke.log`。
- 清除一次性真網 runner／隔離 HOME；未使用、改寫或記錄使用者憑證，未重啟使用者 App。未驗真實已授權帳號收藏寫入；本輪未改 UI，保留前輪畫面與收藏欄契約。

## 2026-10-15 — 按現有功能重整 Favourite 收藏介面

- 保留作品／連結雙欄與現有 owner，搜尋／排序在上方，開啟／編輯／移除在列表下方；移除空列交錯底色，連結新增表單改為網址及標題兩行。繁體中文操作與空態提示，不清除收藏、偏好或自訂 Layout。
- 作品列直接顯示現有收藏分類與待同步旗標，提供五種分類、未分類與待同步篩選，沿用組件私有狀態保存；舊僅排序狀態仍可讀取。分類修改／重試同步仍在詳情，不新增遠端寫入。篩選中禁止拖曳重排，避免以部分清單覆寫全體順序。
- 收藏更新無項目時收為 84 pt 提示，有項目時恢復更新列；標準更新＋收藏雙欄形狀使用列表內部捲動。正式畫面發現原組件 180 pt 最小高度仍撐大空更新區，已修正渲染約束；不改寫保存的 Layout。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動本次來源正式 AppDelegate／Workspace：新增真實 Bilibili 連結、開啟 Bangumi 328609 並收藏，從收藏按鈕重開詳情、設定在看後顯示在看／待同步；未登入未寫入遠端。冷重啟保留分類及待同步篩選。最終產物再次驗證未分類排除在看作品、在看篩選顯示該作品，以及移除確認後取消仍保留收藏。
- 已檢視最終 960×740 與 1280×820 視窗截圖，空更新區縮短、雙欄操作與新增表單可見；證據 `.build/favorite-ui/final-minimum.png`、`final-wide.png`、`final*.ax`、`build-final.log`。README 同步。正式隔離 App 已退出，臨時 driver、App 副本與 profile 已清除；使用者原 App／資料未改動。
- 未驗有新集數的遠端更新資料、真實帳號同步、拖曳排序、全部 Skin／字級、最低 macOS／Intel 或播放。本輪以正式 UI 煙霧驗證，不新增永久文字／實作綁定測試。

## 2026-10-15 — 修正收藏寫入 HTTP 202 被誤判失敗

- 使用者 test App 頁面回報 `Expected HTTP 204, received 202`，未重跑舊行為確認。讀取 Xcode 最新 `Run-IINA-ANI-2026.10.15_21-49-07-+0800.xcresult`：Build／Run succeeded，但 ConsoleLogSection.items 為空，不能聲稱日誌捕捉到該錯誤。
- Context7 的官方 API 文件仍列 POST 收藏成功碼 204；核對 [Bangumi server 的 PostSubjectCollection](https://github.com/bangumi/server/blob/ba9ba234f718c18193ae15bed45e5501ae5b856d/web/handler/user/post_subject_collection.go#L44-L57)，updateOrCreateSubjectCollection 成功後回 202，上游測試也要求 StatusAccepted。根因為 BangumiService 將成功碼鎖死 204；不是此次回應被空內容序列化吞掉。
- 收藏寫入限定接受 202／204，其餘未支援的 2xx 及 HTTP 錯誤仍拒絕；維持原有帳號／關聯／修訂／取消檢查及成功確認後清除待同步流程。不新增自動重送、輪詢、憑證讀取或 UI 開關。
- Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED，`Tests/run-w4-bangumi.sh` 全通過：實際 AccountHTTP／Alamofire URLProtocol 路徑涵蓋空 202／204，拒絕 200／201／203／206 與 HTTP 錯誤；WorkSync 的 202 fixture 驗證分類保存、待同步清除及既有失敗／競態保護。
- 另以最終 App dylib 的 BangumiService→BangumiWorkSync→Core Data 執行一次性 loopback HTTP 煙霧，URLSession 經真正本機 socket 接收空 202／204，兩者皆觀察 pending true→false、持久模型分類 doing、origin network；傳輸 closure 僅將網址導向本機伺服器，不是 Bangumi 公開帳號驗證。證據 `.build/collection-status/accepted-build-regression.log`、`accepted-smoke.log`。
- README 同步重試方式。移除一次性 runner／Core Data model／隔離 HOME 及上游檢查副本；未更動使用者帳號或收藏、未啟停使用者 test App。未使用真實授權帳號寫入 Bangumi，需以更新建置重試既有分類才可確認使用者實際帳號結果。

## 2026-10-15 — 載入在線收藏與移除未分類

- 作品收藏新增「載入在線收藏／取消載入」，使用目前 Bangumi 帳號讀取 `/v0/me` 與全部番劇收藏分頁，包含五種分類；所有頁面成功後才合併。按 Bangumi ID 去重，保留本機名稱、來源、待同步及載入期間的新分類／移除操作，不刪除遠端缺項的本機收藏，不執行遠端寫入。帳號切換、取消、分頁失敗不匯入部分清單。
- 詳情僅保留五種分類，新收藏預設想看；收藏篩選移除未分類，保存鍵改用具名分類並轉換舊數字索引。舊 nil／非 pending 收藏補為本機想看，不自動產生遠端命令。預設遷移只修改原 JSON 的 collectionStatus，保留舊分類遷移所需的缺省欄位與未知欄位。
- 首輪既有 R3 遷移回歸揭露整筆 Work 重編碼會破壞舊 payload 缺省欄位；修正為單欄補值後，最終 Debug BUILD SUCCEEDED，`Tests/run-w4-bangumi.sh`、`Tests/run-w5-favorites.sh` 全通過。覆蓋分頁／重複、五分類、待同步／並行修改／移除、錯誤／帳號切換／取消及舊收藏遷移；建置與測試輸出保留於本次 session artifacts。
- 一次性 loopback HTTP→最終 App dylib→SQLite 煙霧連續匯入兩次，確認兩頁合計三筆、無重複、本機待同步分類與名稱保留、遠端在看／已看套用；正式 AppDelegate／Workspace 隔離啟動讀到這三筆，實際按載入在線收藏呈現未登入錯誤且本機三筆保留。證據 `.build/online-collections/http-smoke.log`、`favorites.ax`、`signed-out-load.ax`。這不是公開 Bangumi 已登入帳號驗收。
- 使用者隨後要求停止驗證、由其自行驗證真實帳號；立即停止，未繼續分類選單、截圖或其他驗證。已關閉自己的隔離 App、清除臨時 driver／runner／模型／App 副本及 profile，保留證據；未操作使用者帳號或 App。README 已同步功能與安全邊界。

## 2026-10-15 — 收藏按鈕單列分類彈窗與收藏頁重試

- 依本輪最終要求，詳情收藏分類移入「收藏作品…／已收藏作品…」彈窗，僅顯示想看、在看、已看、擱置、丟棄一列按鈕；點選即提交並關閉，移除下拉選單、說明文字、額外確認／關閉按鈕及未提交草稿狀態。點外部或 Escape 可關閉；開啟彈窗本身不新增收藏。已收藏的目前分類停用，避免以相同分類在詳情重試同步。
- 作品收藏頁新增「重試同步」，只對選取且待同步的作品啟用；提交時重新讀取目前保存的分類，沿用 BangumiWorkSync 的本機保存／同步／競態防護。離開頁面取消其請求及過期 UI 回覆；連結收藏不新增同步操作。README 同步最終操作，先前中途二次確認方案已被單擊分類方案取代。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED。使用本輪產物的隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace；AX 實際觀察彈窗只有五個分類按鈕，已看停用，單擊擱置後彈窗消失，SQLite 精確作品分類由 2→4、收藏仍一筆且 pending 保留。另以全新隔離 profile 驗證：開啟彈窗收藏數仍為零，單擊在看後變成一筆收藏、分類為 3／pending true，彈窗已關閉，無二次確認。收藏頁選取後實際按重試同步，未登入錯誤如實顯示、分類與 pending 未遺失。新收藏持久化證據為 `.build/collection-popover/direct-new-favorite.json`。
- 已檢視正式視窗截圖 `.build/collection-popover/direct-buttons-popover.png`、`direct-favorites-app.png`；AX 與持久化證據同目錄。退出自己的隔離 App，移除臨時 driver／seed、App 副本及隔離資料；未更動使用者收藏或帳號。未使用真實授權帳號寫入 Bangumi，未測全部 Skin／字級、最低 macOS／Intel 或播放；本輪未新增永久測試。

## 2026-10-15 — 設定合併單頁與分類捲動同步

- WorkspaceSettingsController 將五組設定完整放入同一個文件，新增區段標題；左側分類只捲動定位、不再篩掉其他組或重建控制項。監聽共同 clip bounds 並於版面更新同步分類選中狀態，頁尾短「關於」區段仍能正確選中。帳號等資料重建保留原捲動位置及仍在編輯的控制項焦點；搜尋直接定位到設定列頂部，不因跨組結果僅出現在畫面下方而保留前一分類高亮。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED（本次 session build artifact 31）。SourceKit 獨立診斷無法解析 SDWebImage module，未當作編譯結果；完整 Xcode 建置成功。未修改偏好鍵、設定命令 owner 或資料格式；README 同步操作。
- 本輪最終產物以隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace：實際操作全部五個分類及頁尾；AX 捲軸往返、原生 HID 滾輪由來源→播放→來源均同步高亮。從外觀區搜尋 autoplay 僅一筆，Enter 後同源自動連播置頂並聚焦、播放分類選中。中間產物亦實際切換該開關 1→0→1；最後僅調整搜尋捲動對齊。960×740 與 1280×832 實際視窗已檢視；離開到發現再回設定，捲動比例 0.9→0.899961（像素取整），仍選中下載分類。
- 證據：`.build/settings-page/aligned-*.ax`、`aligned-search.png`、`aligned-minimum.png`；建置完整輸出在 session artifact。退出隔離 App，清除一次性 AX driver、App 副本及 profile；未關閉使用者原 App、未改寫其設定或帳號。未測實體觸控板、全部 Skin／放大字級、最低 macOS／Intel、登入或播放；本輪未新增永久測試。

## 2026-10-16 — 本地番劇完整隊列交給外部播放器

- 根因：本地入口只交給播放器一個檔案，後續由 App 在 EOF 後另開下一集。真實舊產物從三檔資料夾選第 2 集時，mpv IPC 的 playlist 確認只有該檔。改為重用既有同資料夾影片篩選／自然排序，完整載入前後所有集數，保留所選集數與續播秒數；不遞迴、不加入 XML／音訊／隱藏檔／符號連結。
- PlayerProgressSession 以每次載入的身份／generation 分開保存觀看進度，監聽原生 EOF 並在同一播放器內換集；手動選播、停止／關閉、錯誤與過期回呼不重複開啟播放器。keep-open=always 讓 App 的連播開關控制自然換集，停用時完整隊列仍可手選，末集保留最後畫面。各檔使用獨立 XML／外掛 payload，不沿用上一集選項。
- IINA 正式實跑揭露 URL scheme 未建立可用的私有 IPC；直接交單檔給 CLI 又會被 IINA 非同步自動加檔而重複。最終改由 CLI 匯入完整 M3U、指定起始 index，列表以 file URL 編碼檔名，後續每檔選項透過原生 IPC 設定。另實跑確認 M3U 的 EXT VLCOPT 不會套用 referrer，已移除該無效格式；所選檔需要 XML 時才以原生 per-file options 重新載入並保留續播秒數，之後回選該檔不繼承最初斷點。不修改使用者的 IINA 偏好或外掛；mpv 沿用原始檔啟播，IPC 補齊完整隊列。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO BUILD SUCCEEDED（`.build/local-queue/build-xml-options.log`）。`Tests/run-dependency-regression.sh --unit` 全通過；`LOCAL_QUEUE_SMOKE=1 bash Tests/run-dependency-regression.sh --playback` 通過真實 mpv 0.41.0 的自然順序／中間集起播、7.25 秒續播（實際 7.3）、引號／Unicode／換行檔名、M3U 匯入、每檔選項與原集回選、各檔歷史重讀，以及連播開／關。過程回歸實際抓到 playlist-move 目的索引語義與 EOF 後換集仍暫停，均已修正後通過。
- 本輪來源產物的隔離 Bundle ID／HOME／CFFIXED_USER_HOME，走正式 AppDelegate／Workspace 的開啟網址→本地詳情→播放所選集數。IINA 與 mpv 真實 IPC 均觀察三項 `Episode 1 → 2 → 10`，所選第 2 集保持 current；IINA 最終沒有重複。手選第 1 集並 seek 至自然 EOF 後，均在原 PID／socket 接續第 2 集、time-pos 約 1 秒、pause=false，沒有另開播放器。已檢視兩者解碼測試圖與正式來源窗口截圖；隊列內容以即時 IPC 證明，不把未顯示的側欄當作視覺驗收。
- 正式 IINA 的同名 XML fixture 亦經實際 per-file referrer 解碼確認 type=1、獨立 XML 檔與空 URL choices（不觸發外掛重建隊列）；選下一個沒有 XML 的檔案時 referrer 清空，三項隊列及後續自然 EOF 換集仍保持。證據：`.build/local-queue/before-playlist.json`、`formal-playlist.json`、`formal-transition.json`、`formal-iina-playlist.json`、`formal-iina-transition.json`、`formal-iina-xml-options.json`、`formal-source-window.png`、`formal-iina-queue.png`、`queue-smoke-evidence.json`、`evidence.json`。README 與設定說明同步。已清除本輪一次性程式／媒體／隔離 App 及 profile，保留去敏證據；未修改使用者原有下載、影片或歷史。
- 限制：實測為本機安裝 IINA CLI 與 mpv、自製影片；未重驗歷史 IINA-Danmaku 版本、IINA 外掛 XML 視覺呈現、遠端播放、最低 macOS／Intel 或正式簽署，不擴大為全播放器／全產品驗收。

## 2026-10-16 — 繼續觀看右鍵刪除記錄

- 續看卡片新增原生右鍵「刪除記錄」，依開啟選單時的穩定記錄 ID 刪除，不依賴目前選取列或刷新後的索引；空白區及預覽不提供刪除操作。沿用 PlaybackHistoryStore 原子保存與變更通知，寫入失敗沿用面板錯誤呈現，不先移除畫面資料。
- 刪除僅作用於該集歷史，其他集數進度、影片、下載及收藏保留；阻止刪除前已發出的 EOF 目錄查詢將該集恢復為保留追更。README 同步操作及同作品其他集可能接替顯示的規則。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功，`bash Tests/run-dependency-regression.sh --unit` 全通過。新增永久回歸覆蓋手動刪除保留追更記錄、過時 EOF 回覆不復活、冷重讀、其他集精確秒數保留與重複刪除。
- 本次產物以隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace，實際右鍵開啟選單並執行刪除：指定卡片消失，另一筆仍為 71.25 秒；正常退出並冷重啟後仍只剩保留卡片；再刪最後一筆，磁碟 archive 為空且首頁呈現緊湊空態。已檢視 `.build/history-delete/menu.png`、`empty.png`，AX／持久結果見同目錄 `before.ax`、`after.ax`、`restart.ax`、`empty.ax`、`evidence.json`。
- 驗收工具跨程序操作選單時選單曾消失，改為同一原生 driver 連續右鍵與 AXPress 完成驗證，未為此修改產品選單邏輯。驗證後退出自己的隔離 App 並移除一次性 driver、App 副本與 profile；未操作使用者原 App／資料。未重驗播放、所有 Skin／字級、最低 macOS／Intel 或磁碟寫入失敗畫面。

## 2026-10-16 — 簡潔現代功能圖標資產集

- 依現有探索／導航、播放與彈幕、內容與來源、下載與外觀及通用操作，繪製 40 個單色圓角線性圖標。原稿使用 24×24 網格、1.75 px 線寬及 currentColor，匯出 24／48／96 px 透明 PNG、明暗整套預覽、可離線開啟的搜尋／尺寸／顏色預覽及 ID 對照。原稿與匯出程式位於 `Design/Icons/`，另提供整套 ZIP。
- 新增既有 Asset Catalog 下的 `FunctionIcons/`，共 40 組 `ani-` 前綴 SVG imageset，設定 Template 著色及保留向量。現有按鈕尚未指定新素材，AppIcon、上游圖標及授權文件保留；未改動播放、資料或工作區行為。
- 已檢視淺色／深色總覽及 16／20／24 px 實際尺寸。匯出檢查確認 40 個不同圖稿、120 個 PNG 尺寸正確／有有效內容／邊界透明；直播弧線已增加留白。預覽內嵌 JavaScript 語法檢查通過。Xcode actool 在 macOS 13.5 target 編譯成功，assetutil 確認 40 個素材名稱及 120 個 rendition，保留向量及 Template metadata；證據 `.build/function-icons/actool.log`、`catalog.json`、`export-check.json`、`small-sizes.png`。
- 瀏覽器安全政策不允許 file URL，未繞過限制，故互動 HTML 未做瀏覽器操作驗收；使用靜態圖片檢視圖標。actool 日誌包含隔離環境的 CoreSimulator 服務告警，macOS Assets.car 仍成功產生。此輪為素材交付，未執行完整 App 建置／啟動或產品 UI 驗收。

## 2026-10-16 — 將功能圖標套用至現有按鈕

- 新增集中式 `WorkspaceIcon` 與 `NSButton.setFunctionIcon`，以複製的 Template NSImage 指定 16 pt 圖標，避免改動共用素材尺寸。WorkspaceSkinButton 保存預設功能圖標；Skin 的 iconAsset 優先，未指定或移除覆寫時回退至預設圖標。保留原生核取方塊、單選狀態及組件密度指示，不以裝飾圖標取代狀態圖片。
- 接入固定工具列、頁面導航、搜尋／推薦命令、收藏開啟／編輯／移除／新增／在線載入／重試同步、詳情／來源／快速下載、Torrent 搜尋／匯入／選檔／下載／播放，以及設定、來源訂閱、Skin 管理和 Layout 編輯的主要命令。JSPlayer 重新載入與彈幕設定採 18 pt 圖標並補輔助名稱；本地影片／XML 選檔按鈕亦接入。保留文字、target/action、快捷鍵、業務 owner 及動態停用規則；在線收藏的取消／恢復載入及推薦重試會同步切換圖標。
- 來源窗口底部改為兩組操作，520 pt 以下垂直排列，為新增圖標留出空間；寬窗口仍並排。README、圖標使用說明及 ZIP 說明同步。
- 最終 Debug／CODE_SIGNING_ALLOWED=NO 完整建置 `BUILD SUCCEEDED`，證據 `.build/icon-buttons/build.log`。沙盒內首輪建置無法寫 SwiftPM／Clang 快取，獲准後重新建置成功；CoreSimulator 版本告警不影響 macOS 建置。
- 以獨立 Bundle ID 及 HOME／CFFIXED_USER_HOME 的正式來源 AppDelegate／Workspace 啟動，使用 CUA 實際操作並檢視截圖：淺色主頁與收藏雙欄、停用命令、設定原生單選、深色隔離預覽及套用、URL 搜尋結果開啟 Bangumi 詳情、在線／BT 快速下載操作列；未提交 P2P 匯入、播放或下載。最終建置重新複製啟動，再次檢查下載頁圖標與停用狀態。AX／截圖在本次對話 CUA 輸出；摘要 `.build/icon-buttons/verification.json`，來源產物複製核對 `.build/icon-buttons/final-product-check.json`。
- CUA 確認自己的測試 App 已退出，已移除臨時 App 副本及隔離 HOME，保留建置產物與驗證摘要；未改動使用者原 App 的收藏、下載或帳號。未實測 460 pt 來源窗口底部排列、所有自訂 Skin／放大字級、JSPlayer／本地選檔的執行畫面、最低 macOS／Intel 或播放／下載業務鏈；本輪未新增永久測試。

## 2026-10-16 — 放大主頁側邊導航圖標

- 發現、搜尋、下載、設定、收藏及其他頁面導航的功能圖標由 16 pt 增至 24 pt，按鈕至少 40 pt 高、導航間距由 8 pt 增至 10 pt。設定 imageScaling 為 scaleNone，避免原生 toolbar 按鈕再縮小圖標；保留原文字、選中及頁面路由。
- Skin 自訂按鈕圖標的載入目標至少等於功能圖標尺寸，使導航素材亦採用 24 pt 目標；一般命令的既有 20 pt Skin 載入尺寸保留。圖標使用說明同步。
- 最終 Debug／CODE_SIGNING_ALLOWED=NO 完整建置 BUILD SUCCEEDED，證據 `.build/nav-icons/build.log`。隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動本次來源的正式 AppDelegate／Workspace，檢視發現及搜尋頁截圖，實際點選搜尋確認切頁後仍顯示放大圖標。AX／截圖見本次對話 CUA 輸出；摘要 `.build/nav-icons/verification.json`。
- 測試 App 已退出，臨時副本及隔離 HOME 已移除；未更動使用者原 App 資料。未重跑自訂 Skin、放大字級、最低 macOS／Intel 或播放／下載流程；本次為顯示尺寸調整，未新增永久測試。

## 2026-10-16 — 側邊導航以圖標為主、文字置下

- 發現、搜尋、下載、設定、收藏及其他頁面導航改用 32 pt 圖標在上、文字置中在下；以 imageHugsTitle 將圖文作為一組居中，按鈕至少 64 pt 高、間距 10 pt，側欄寬度收為 112 pt。改用可變高度的原生按鈕外觀並保留 scaleNone，圖標不被原生 toolbar 的固定高度壓縮。
- WorkspaceSkinButton 增加 functionIconPosition，預設仍為 imageLeading；頁面導航指定 imageAbove。初始素材與 Skin 刷新均沿用指定排列，保留 target/action、頁面 ID 及輔助使用名稱。側欄與內容區寬度共用同一計算值，修正原先內容區殘留的 184 pt 側欄扣減，避免縮窄後多留空白。圖標使用說明同步。
- 最終 Debug／CODE_SIGNING_ALLOWED=NO 完整建置 BUILD SUCCEEDED，證據 `.build/nav-labels/build.log`。使用獨立 Bundle ID／HOME／CFFIXED_USER_HOME 啟動本次來源的正式 AppDelegate／Workspace；檢視發現頁與最終搜尋頁截圖，實際點選搜尋確認切頁／Skin 狀態刷新後仍為上圖下文，修正後內容區貼齊 112 pt 側欄。AX／截圖位於本次對話 CUA 輸出；摘要 `.build/nav-labels/verification.json`。
- CUA 確認自己的預覽 App 已退出，臨時副本及隔離 HOME 已移除，使用者原 App 資料未更動。未重跑深色／自訂 Skin、最低視窗尺寸、放大字級、最低 macOS／Intel 或播放／下載流程；本輪未新增永久測試。

## 2026-10-16 — 移除側欄名稱與整列導航選取

- 移除側欄頂部 IINA-ANI 名稱；導航按鈕填滿 112 pt 側欄左右各 8 pt 留白內的整列，圖文居中、圖標在上文字在下、至少 64 pt 高、間距 6 pt。未選取時取消原生底框，選中／滑過／按下時使用不同強度的整列圓角背景；保留 Skin 明確指定的狀態背景與圖片。輔助使用值新增已選取／未選取，頁面 ID 與動作沿用原有路由。
- WorkspaceSkinButton 提供原生底框開關及樣式套用 hook，僅導航覆寫。實際啟動先後發現跨 view 寬度約束在加入共同父層之前啟用、以及 Skin 刷新反覆切換底框導致圖文未繪製，均已修正後重新建置與啟動確認。圖標使用說明及 ZIP 內說明同步。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 完整建置 BUILD SUCCEEDED，證據 `.build/nav-rows/build.log`。隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動最終來源產物的正式 AppDelegate／Workspace，實際檢視深色發現頁、切換搜尋後的整列高亮與 AX 選取值，以及淺色發現頁；圖文完整顯示、側欄名稱已消失。截圖見本次對話 CUA 輸出，摘要與來源產物雜湊比對見 `.build/nav-rows/verification.json`。
- CUA 確認自己的測試 App 已退出，已移除臨時 App 副本及隔離 HOME，未操作使用者原 App／帳號／資料。未單獨截取滑過／按下瞬間、全部自訂 Skin、最低視窗尺寸、放大字級、最低 macOS／Intel 或播放／下載流程；本輪未新增永久測試。

## 2026-10-16 — 設定分類沿用整列圖標導航風格

- 五個設定分類取消圓形單選指示及原生固定底框，改用 24 pt 功能圖標在上、文字置中在下，各列填滿分類欄、至少 64 pt 高、間距 6 pt。外觀、帳號、播放、下載、關於分別使用 appearance、account、play、downloads、info 圖標，選取值以已選取／未選取提供輔助使用資訊。
- 將 WorkspaceNavigationButton 移至共用外觀檔案，主導航與設定分類共用圓角整列選中／滑過／按下背景及 Skin 覆寫優先規則。分類仍只捲動共同文件；同步選取交由按鈕原有狀態追蹤處理，保留滑過及焦點狀態。設定搜尋、偏好與資料 owner 不變。README、圖標說明及 ZIP 內說明同步。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 完整建置 BUILD SUCCEEDED，證據 `.build/settings-nav/build.log`。本輪最終產物以隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace；檢視深色及淺色設定頁截圖，五項圖文完整、同寬且只有目前分類選中。實際點選來源、播放、下載與關於，各次 AX 僅對應分類已選取且文件定位；從頁尾手動向上捲動後，自動選中播放分類。截圖與 AX 見本次對話 CUA 輸出，建置產物程式碼／資產雜湊比對與摘要見 `.build/settings-nav/verification.json`。
- CUA 確認自己的測試 App 已退出，臨時 App 副本與隔離 HOME 已移除，使用者原 App／資料未更動。未單獨截取滑過／按下瞬間、全部自訂 Skin、最低視窗尺寸、放大字級、最低 macOS／Intel 或重新操作搜尋、帳號、播放／下載流程；本輪未新增永久測試。

## 2026-10-16 — 收窄設定分類欄與縮小圖標

- 設定分類欄預設寬度由 148 pt 收至 112 pt，圖標由 24 pt 縮為 20 pt，按鈕最低列高由 64 pt 收為 56 pt，保留上圖下文、6 pt 間距與整列高亮。同步縮減字型計算的高度留白；仍以文字抗壓縮及較低優先級的偏好寬度容許大字級擴寬。圖標說明及 ZIP 內說明同步。
- 最終 Debug arm64／CODE_SIGNING_ALLOWED=NO 完整建置 BUILD SUCCEEDED，證據 `.build/settings-compact/build.log`。隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動本次來源的正式 AppDelegate／Workspace；實際檢視深色設定頁，五個分類文字完整、圖標及欄寬縮小，點選外觀分類可定位並更新唯一選中狀態。截圖與 AX 見本次對話 CUA 輸出；摘要 `.build/settings-compact/verification.json`。
- CUA 確認自己的測試 App 已退出，臨時 App 副本及隔離 HOME 已移除；未更動使用者原 App／資料。未重跑淺色／自訂 Skin、放大字級、最低視窗尺寸、最低 macOS／Intel 或帳號、播放／下載流程；本輪未新增永久測試。

## 2026-10-16 — Hanime1 改為混合站點分類

- 移除 SourceRegistry 對 Hanime1 整站動畫的宣告，沿用既有混合站點規則：沒有單片內容證據時返回 unknown／待確認，不以 watch 路由判定番劇或一般影片。網址身份、解析器及品質選擇未改動；不重寫既有收藏或持久資料。
- 新增實際 Hanime1 watch URL 的分類回歸，經生產 registry 建立影片身份並確認分類待確認。Debug／CODE_SIGNING_ALLOWED=NO 建置成功；Tests/run-w3-sources.sh 全部通過，涵蓋新增分類路徑與既有來源、搜尋及訂閱回歸。
- 本次未操作 App UI 或重新驗證遠端影片播放；驗證限於建置及連結生產 App dylib 的來源分類執行。

## 2026-10-18 — 自定義佈局改為原生畫布直接編輯

- 重建 WorkspaceLayoutEditorController：同一視窗左側嵌入原生工作區預覽，右側為可捲動分區側欄，固定顯示目前選取；工具列保留保存、取消、撤銷、重做與恢復內建草稿。組件中文名稱共用，尺寸／比例與斷點說明分離，不再以原始組件 ID 作主要標籤。
- WorkspaceRenderer 增加編輯專用選取標題與邊框；點選組件、容器或頁面同步編排樹，僅改選取不重建整個畫布。原生分隔線保留，預覽嵌入後依實際 host 尺寸繪製，關閉清理預覽 owner。一般工作區與 Skin 預覽維持原路徑；草稿仍明確保存，服務隔離不變。README 同步操作方式。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。本次產物複製為獨立 Bundle ID／HOME／CFFIXED_USER_HOME，啟動正式 AppDelegate／Workspace，透過原生 Accessibility 操作實際視窗：畫布選取同步標題與高亮；尺寸 760×210 修改後吸附為 768×320，撤銷／重做恢復精確值；取消重開仍為原尺寸；收藏分隔比例 0.50 改為 0.60，明確保存後重開編輯器及正常退出／冷重啟均保留。
- 已檢視正常與 1120×760 窗口截圖，原生畫布、側欄及選中邊框可見，未另開預覽窗口。證據 `.build/layout-canvas/editor.png`、`selected.png`、`compact.png`、`saved.png` 與 `verification.txt`。自己的驗證 App 正常退出，臨時 driver、App 副本、隔離 profile 與原始日誌已移除；未更動使用者現有資料。
- 限制：本輪未逐項重驗樹狀拖放、鼠標拖曳分隔線、所有巢狀分頁／自訂 Skin、淺色與放大字級、最低 macOS／Intel；未執行播放／下載業務鏈。未新增永久測試；驗證為本次建置的正式 App 原生操作，不以單元測試或隔離 host 代替。

## 2026-10-18 — 功能頁面進場動效、XML 載入與預設

- WorkspacePage 增加 motion 屬性，舊 JSON 缺項預設無動效；提供無／淡入／滑入／縮放與時間、不透明度、位移、縮放、曲線。頂層／巢狀分頁／寬度斷點共用驗證與持久化，複製、移動、移除組件不丟失頁面動效。
- 編排側欄新增參數、預設、XML 本機載入與畫布重播；沿用草稿交易、撤銷／重做及明確保存。Renderer 在頁面切換套用 presentation-only Core Animation，不改最後 layout 值；系統減少動態效果時不播放。
- XML 接口 WorkspacePageMotion.loadXML(from:)／decodeXML(_:) 限 UTF-8／16 KiB，嚴格驗證版本、完整屬性與有限範圍，拒絕 DTD／entity／額外內容，不讀外部資源。四個範例在 Examples/PageMotions；README 同步操作與格式。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED。Tests/run-workspace-layout.sh 通過，包含 XML／非法輸入、舊新 JSON、巢狀驗證、交易與斷點隔離、複製／移動／移除保留 motion、原子保存重讀；移除僅固定預設排序／範例複本的非行為斷言。
- 本次建置產物使用獨立 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace。實際 Accessibility 操作驗證：滑入預設、撤銷回無動效／重做、3 秒＋200 pt 自訂動效重播（已檢視動畫中與完成後截圖）、原生檔案面板匯入 zoom.xml、保存後切頁／重開編輯器、負時間拒絕、取消及正常退出／冷重啟保留 0.25 秒／0.96 倍縮放。截圖保留於 .build/page-motion/{mid-animation,editor,reopened}.png。
- 驗證 App 已正常退出，隔離 App 副本／HOME 已移除，未修改使用者現有佈局或偏好。限制：巢狀動效及斷點隔離本輪以回歸驗證，未逐一操作全部巢狀 UI；未切換系統減少動態效果、最低 macOS／Intel、淺色／自訂 Skin／放大字級，也未重跑播放下載業務鏈。

## 2026-10-18 — Skin 同步支援頁面動效 XML

- Skin manifest 的 entryPaths 新增可選 pageMotion，指向包內 XML；SkinPackage 保留已驗證動效。明列文件必需存在，沿用 16 KiB／UTF-8／有限數值與 XML 安全限制；檔案必須進入 exact whitelist，套用前磁碟與記憶體設定須相符。XML 納入 digest、作者快照、安裝及原包／衍生匯出，未明列 XML 與非素材 XML 仍拒絕。
- SkinAppearance 統一解析動效：非 .none 的頁面自訂值優先；中性頁面使用 Skin 預設，無 Skin 配置則維持無動畫。主頁、巢狀 tabs、編排重播共用此規則；純換皮不寫入 Layout，系統減少動態效果仍優先。編排說明、根 README、Skin 格式文件已同步。
- minimal／full 作者範例與 generator 分別配置淡入／滑入 XML；修正範例 package.sh 遺留的 IINA+ 路徑，使現行 IINA-ANI 工程可直接打包。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED；Tests/run-skin-appearance.sh、Tests/run-skin-package-store.sh 通過，覆蓋優先序／切換／舊包、安全拒絕、XML digest、安裝與原包／衍生包匯出重匯入（含無 Layout）、作者基礎／斷點／巢狀頁動效保留。generator 在臨時目錄實際產生兩組 XML；Examples/Skins/package.sh 成功驗證並產生 minimal.iinaskin／full.iinaskin。
- 本次 App 以隔離 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate；開啟含 3 秒／100 pt XML 的測試包，實際切換原生預覽搜尋頁並檢視動畫中／完成截圖。未勾作者 Layout，套用後正式頁面同樣播放動效；Layout 檔案套用前後 SHA-256 相同（ee1e36b50879ae4fe29d74d307abaf0dee05756f389e64223a34a4cd0e8b1388）。正常退出／冷重啟後動效仍在，截圖位於 .build/skin-motion/{preview-motion,preview-settled,applied-motion,applied-settled,reopened-motion}.png。
- 驗證期間作者目錄檔案對話框的鍵盤自動化未完成，後改以 .iinaskin 檔案開啟正式流程；ditto 產生的試驗 ZIP 被既有格式限制拒絕，改用相容 ZIP 完成正式預覽／套用，未放寬 archive 安全規則。目錄重載及分享完整鏈由既有服務回歸驗證，未宣稱 UI 逐項操作通過。未測最低 macOS／Intel、系統減少動態效果切換、放大字級或播放下載流程。
- 驗證 App 已正常退出，臨時 App／隔離資料／作者測試目錄與試驗包已清除，保留截圖與正式範例打包產物；未改動使用者既有 Skin 或 Layout。

## 2026-10-18 — 編輯佈局簡化為分頁工具與互動組件

- WorkspaceLayoutEditorController 將長側欄拆為「編輯／新增／編排／進階」，固定保留目前選取資訊；頁面動效、組件尺寸、分隔比例依選取類型顯示。保留原編排樹拖放、頁面管理、容器與斷點功能，未改資料格式或業務服務。
- 組件類型下拉＋新增按鈕改為一鍵加入組件清單；成功後自動選取新組件並返回編輯。寬高新增 32 pt 步進器，精確輸入按 Return 套用；比例新增原生滑桿，放開時更新草稿，保留精確輸入與畫布分隔線。沿用最小尺寸、交易驗證、撤銷／重做、取消與明確保存。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED；Tests/run-workspace-layout.sh 通過。沒有新增僅檢查 UI wiring 的永久測試。
- 本次建置以獨立 Bundle ID／HOME／CFFIXED_USER_HOME 啟動正式 AppDelegate／Workspace，Accessibility 實際操作通過：畫布選取後顯示對應工具、尺寸步進（760×210 → 768×256）、撤銷／重做、一鍵加入收藏更新並自動選取、撤銷新增、取消重開恢復原尺寸、比例滑桿 0.5 → 0.545、保存重開保留比例，以及編排／進階分頁切換。
- 已檢視真實窗口截圖 `.build/layout-interactive/{component,palette,split}.png`；README 更新操作方式。驗證 App 正常退出，自己的 App 副本、隔離 profile、driver 與原始日誌已清除。
- 限制：本輪滑桿由 Accessibility increment 操作，未另測鼠標拖動與精確輸入 Return；未逐項重驗樹狀拖放、全部巢狀容器、冷啟動、最低 macOS／Intel、VoiceOver 或播放下載流程。

## 2026-10-20 — 修復 Renderer 分頁／分隔線與 Skin 隱藏動效匯出

- 統一工作區可見組件的 attach／detach 生命週期：巢狀及頂層分頁切換會恢復服務、收藏、產品與設定面板，僅處理可見性轉換，不重新啟動無關面板。保留原控制器與畫面狀態。
- 原生分隔線不再要求編輯器 callback 才處理鼠標事件；普通工作區可直接拖曳，保留拖動後比例於縮放及相同模型的重新配置。編輯器仍在一次手勢完成後提交比例。保留的 NSTabViewItem 依模型重新排序，維持有效選取並在填充期間抑制操作回呼。
- Skin archive 匯出與更換差異計算不再跳過已驗證的隱藏檔案／隱藏目錄；保留原 exact whitelist、路徑、類型及大小限制。新增 `.motion.xml`／`.motions/page.xml` 原包及衍生包重匯入、精確 XML／動效及更換差異回歸。新測試首輪將更換結果誤判為 installed，已依既有 replaced 契約修正後通過。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置 BUILD SUCCEEDED；`Tests/run-workspace-renderer.sh`、`Tests/run-workspace-layout.sh`、`Tests/run-skin-appearance.sh`、`Tests/run-skin-package-store.sh` 全通過。新增 Renderer 回歸連結生產 App dylib，覆蓋巢狀祖先切換、搜尋／收藏恢復、無關 owner 不重啟、分頁順序／選取／回呼與原生拖曳及比例保留。另以一次性程式實際執行生產 Skin API，確認修復前失敗的 hidden XML 安裝→兩種匯出→重匯入均保留內容。
- 將本次來源產物複製至獨立 Bundle ID／HOME／CFFIXED_USER_HOME，正式 AppDelegate 啟動並經 Accessibility／鼠標操作：原先隱藏的 B Search 分頁切入後可執行 Search 並更新提示；普通收藏分隔線位置由 583.5 pt 拖至 701.5 pt；編輯畫布將 A 下移後立即呈現 B Search／A／C，撤銷、重做、保存後正式頁面及磁碟順序均一致。已檢視實際窗口截圖，保留 `.build/review-fixes/` 的 AX、截圖與 verification.json。
- 正式產物與隔離副本的 executable／debug dylib SHA-256 相符；驗證 App 正常退出（exit 0），已移除自己的 App 副本、profile、driver、一次性程式與試驗包，未改動使用者原資料。README 同步契約及新回歸入口。
- 限制：本輪未冷啟動、未測最低 macOS／Intel、完整 VoiceOver、所有 Skin／字級或播放下載流程；Skin 匯出重匯入為生產 API 執行，未逐項操作原生保存面板。

## 2026-10-20 — 多語言介面與設定選項

- 「設定 → 外觀與佈局」新增應用程式語言選單：System Default、English、简体中文、繁體中文。偏好及此 App 專用的 AppleLanguages 覆寫立即保存，下次開啟生效；選回 System Default 移除覆寫，不修改系統語言或強制重啟。設定搜尋加入語言同義詞，預覽模式沿用禁止修改全域偏好的規則。
- 主選單、工作區、設定、詳情／來源選擇、收藏、下載／Torrent、Layout／Skin 工具、輔助窗口及 App 自有狀態／錯誤接入標準字串 catalog；主 catalog 1,429 項，JSPlayer 15 項、Open Files 8 項。Open Files storyboard 改用 Base＋catalog 的 variant group，工程加入 zh-Hant。未使用的字串符號生成因標點不同鍵名碰撞而關閉，保留資源編譯及 Swift 字串擷取；依編譯器輸出修正 Torrent 上傳上限的 UInt32 `%u` 格式鍵。
- 內建頁面依穩定 ID 與原始標題顯示翻譯，不改寫保存標題。自訂／改名頁面、媒體／來源資料及作者包內容保持原文；列舉 rawValue、來源解析關鍵詞及持久身份不改動。偏好回歸涵蓋隔離 domain、跨實例保存、無效值及系統語言不受影響；Layout 回歸涵蓋內建標題翻譯、作者標題保留及序列化不變。
- Debug arm64／CODE_SIGNING_ALLOWED=NO 建置成功；`Tests/run-dependency-regression.sh --unit`、`Tests/run-workspace-layout.sh`、`Tests/run-workspace-renderer.sh`、`Tests/run-workspace-detail-episodes.sh`、`Tests/run-skin-appearance.sh`、`Tests/run-skin-package-store.sh` 全通過。1,358 個編譯器擷取鍵全部有翻譯，三語 catalog 的插值型別／位置檢查通過；一次性 Swift 程式完成 4,353 次正式編譯 bundle 查找比對及動態計數格式化。
- 使用獨立 Bundle ID／HOME／CFFIXED_USER_HOME 啟動實際 AppDelegate，透過原生 Accessibility 選單操作與正常退出重開，驗證简体中文 → 繁體中文 → English → System Default；三語設定及內建導航正確，System Default 移除 App 專用覆寫並恢復此機的英文。選擇後本次會話保留原語言並顯示下次啟動提示。自訂「我的自訂頁」及完整磁碟 Layout 未改變；已檢視三語窗口截圖，保留 `.build/language-support/` 的 AX、PNG 與 verification.json。
- 正式產物與隔離副本的 executable／debug dylib SHA-256 相符，五次驗證會話均正常退出 exit 0。已清除臨時 App、profile、driver、一次性程式及測試專用偏好 domain；macOS 偏好 daemon 將該獨立 domain 寫於使用者 Preferences，因此另外移除，未操作既有 App 偏好。README 更新語言選擇、重啟時機及翻譯維護方式。
- 限制：視覺驗證涵蓋設定與導航，未逐一開啟全部對話框；未另測實際播放／下載中的切換、完整 VoiceOver、最低 macOS／Intel 或正式簽署發佈。

## 2026-10-21 — 功能目錄重構與首次 Git 提交準備

- 搬移 153 個 App 檔案：App 啟動／組裝、Features 下的 Accounts／Bangumi／Discovery／Sources／Playback／Downloads／Torrent、Infrastructure 下的 Persistence／HTTP／Cache、Shared，以及 Workspace 的 Shell／Panels／Settings／Layout／Skin。Xcode groups 同步實體目錄，保留編譯身份、資源名稱、單一 Swift module、Core Data schema／資料位置及播放器協議。147 個 App Swift 檔案均在 build phase，所有已解析建置引用與實體 group 路徑存在。
- 43 個測試來源／fixture helper 按功能分類；根層 `Tests/run-*.sh` 入口保留，更新相對 fixture 路徑與所有原始碼引用。同步 bridging header、外掛安裝腳本及 Skin 範例打包入口。搬移前後雜湊核對；內容例外僅為下述 OAuth 配置抽離及兩個檔案中的失效個人路徑註解清除，未趁機改動解析／播放業務。
- 原完整 README 移至 `docs/USER_GUIDE.md`；根 README 改為導覽、建置、驗證與首次提交入口。架構、規劃、研究與歷史記錄分別歸入 `docs/architecture`、`plans`、`research`、`history`，Issue 模板移至 `.github/ISSUE_TEMPLATE.md`；AGENT 同步新位置。保留全部歷史記錄、授權、鎖檔、原生邊界及範例。
- 公開檢查發現 Bangumi OAuth client secret 原為硬編碼。改由共用 `Config/App.xcconfig` 選擇性載入被忽略的 `Config/Local.xcconfig`，再注入 Info.plist；既有值只保留於本機權限 0600 的檔案，公開範本為空。未配置時登入／續期在網路請求前明確拒絕，UI 提示含三語翻譯；既有續期回歸改用合成應用憑證，新增缺失／未展開設定的拒絕回歸。此措施只保護 Git 內容，編譯後桌面 App 仍可被取出 secret；README 建議擁有者輪替原憑證，未代替擁有者操作平台。
- `.gitignore` 補充本機助理狀態、環境秘密、簽署私鑰與語言快取；不忽略 public CA、授權或依賴鎖檔。以專案外的臨時 Git metadata 盤點 617 個候選檔案（約 8 MB），沒有超過 50 MiB 的單檔；既有 OAuth secret 在候選中為零，本機配置確實排除，通用憑證格式檢查未見其他待處理命中。這不是全面安全審計。未在專案初始化 Git、建立 commit、配置遠端或推送。
- 驗證：Debug arm64／`CODE_SIGNING_ALLOWED=NO` 建置 exit 0；project／Info.plist 的 plutil 檢查、HuyaKit manifest 解析、28 個 shell 腳本語法及 116 個本地 Markdown 連結／錨點通過。保留既有 Swift 並行隔離、未使用回傳值等編譯警告，不以抑制警告擴大本次結構重構。
- 20 個行為／打包入口通過：dependency unit（預設）與 HTTP integration；W2／W3／W4／W5／W6／W7；Workspace layout／layout-script／feed-grid／renderer／detail-episodes；Skin appearance／package-store；Work library；Torrent search／HTTP Range；JSPlayer autoplay；Skin examples 實際產生 minimal／full 包。未重跑外部播放器或 Torrent peer 全鏈。
- 正式 AppDelegate smoke：以本次建置的獨立 Bundle ID／HOME／CFFIXED_USER_HOME 副本操作主視窗、設定、Layout 編輯／取消、Skin 管理及影片＋彈幕 Storyboard。空 OAuth 配置顯示明確錯誤且不開 WebView；配置存在時冷重啟後開啟官方 Bangumi 登入表單並取消。已檢視兩種狀態的真實窗口截圖；沒有輸入帳密或執行完整授權。兩次均正常退出 exit 0，副本 executable／debug dylib 與正式產物雜湊一致。
- 證據在本機 `.build/refactor-migration/` 的回歸日誌、兩張 OAuth 截圖與 `verification.json`，不隨 Git 發佈。已刪除自己的臨時 App、profile、driver、原始 App 日誌、範例輸出及測試專用偏好 domain，未清除使用者資料。
- 限制：建置使用既有下載依賴快取，未做全新網路依賴安裝；未完成真實 OAuth 授權／續期、逐站播放／下載、最低 macOS／Intel 或正式簽署／公證驗收。原有未簽收產品關卡不因本次檔案整理變為通過。

## 2026-10-21 — 原始碼倉庫初次匯入準備

- 依使用者要求將本機專案準備匯入已建立的 `Vianssr/iina-ani`，使用 `main` 分支；本機初始化 Git。README 與架構文件改用實際倉庫地址，移除公開文件對本機助理規範的連結。
- `.gitignore` 排除 AGENT／AGENTS、Claude／Gemini 指令、助理設定及個人 IDE 狀態；保留本機檔案。既有排除規則持續保護 `Config/Local.xcconfig`、環境秘密、簽署私鑰、`.build`、npm 依賴與下載外掛。共用 `Config/App.xcconfig` 與空白範本仍是必要建置來源。
- 匯入清單為 616 個檔案，保留全部原始碼、資源、授權與鎖檔。逐檔檢查排除規則、大小與雜湊，候選檔案未命中本機 OAuth 憑證或本輪檢查的 GitHub token／AWS key／私鑰格式；此檢查不代表全面安全審計。
- 本次僅調整發佈排除規則與文件，未更動應用程式碼，未重跑建置或 App 驗收；先前驗證及未簽收限制維持原記錄。這筆記錄描述匯入準備，不將原始碼上傳視為正式 App 發佈。


## 2026-10-22 — 原生前端視覺重設

- 主殼改為 188 pt 文字導覽、搜尋優先工具列與帶日期的發現頁標題。導覽保留保存順序、穩定 ID、選取狀態及固定入口；首頁標題隨共同文件捲動，日期在跨日／啟用／語系通知後更新。沒有改寫使用者 Layout 或 Skin 選擇。
- 內建 Skin 增加語義化字級／字重與暖白、墨藍、琥珀導覽、青綠進度配色；卡片與正文層級分開，原生搜尋及按鈕保留系統繪製與焦點。作者素材、狀態樣式、個人覆寫仍優先，錯誤狀態色不被初始次要文字色覆蓋。
- 發現區使用 16 pt 外層邊距、標題／數量膠囊、Bangumi 標識與更寬的橫向卡片；Trends 保留 210 pt，續看保留既有非空／空區高度，新增清楚的封面、播放提示、集數與實際時間／進度層級。海報標題仍於 hover／鍵盤選取顯示，推薦網格算法、4 pt 間距及 15 pt 尾端保留不變。
- 收藏保留作品／連結雙欄、操作及排序，整理標題、封面、metadata 與空／篩選無結果狀態。設定導覽改為緊湊橫列，外觀命令移除重複標題／長說明，保留搜尋定位、命令及預覽隔離。新增字串補齊 English／简体中文／繁體中文。
- 原始碼檢查：Swift parse、git diff --check 通過；未更動工程引用、套件或資源身份，不另宣稱 manifest／全新依賴安裝驗證。
- 建置：README 指令的 Debug macOS／CODE_SIGNING_ALLOWED=NO App 建置成功；產物在 .build/xcode/Build/Products/Debug/IINA-ANI.app。Workspace renderer、layout、Skin appearance 及 feed-grid 四項相關回歸通過，包含 Skin 覆寫、明暗文字／邊框對比、保留控制器與原生分隔線等既有斷言。
- feed-grid 初跑受系統延後載入的永遠顯示捲軸偏好影響：測試 clip 寬度從 776 變成 759 pt，導致既有固定欄數斷言失敗。腳本僅增加程序內 -AppleShowScrollBars WhenScrolling，使原測試要求的 overlay 幾何穩定；未改使用者偏好、生產網格或斷言。修正後標準入口通過。
- 正式 App 驗證：啟動本次來源建置的正式 AppDelegate／Workspace，檢視實際載入的 Trends／推薦／續看與收藏、設定；操作切頁、Cmd-F、搜尋提交／取消、清除本輪查詢、Layout 編輯／取消及淺色隔離預覽／取消。正常退出重開後檢視最終首頁與設定，保留原外觀偏好與使用者資料。搜尋停在載入後取消，未將其記為搜尋結果成功；未觸發播放或下載。
- 最終真實視窗截圖：.build/ui-redesign/discovery.png、settings.png；建置與四組回歸日誌同目錄。淺色預覽與收藏畫面另已透過 CUA 當場檢視。App 留在最終首頁供使用者檢視。
- 限制：本輪未完整重驗播放／彈幕／下載／登入、自訂 Skin 全矩陣、VoiceOver、Intel／macOS 13.5、正式簽署；GUI 拖曳未成功改變視窗尺寸，不宣稱 960×640 實際視窗驗收。既有產品關卡維持原狀。

## 2026-10-22 — 頂部工具列分組與標題整理

- 頂部依序分為搜尋／開啟、日曆／活動任務、佈局／功能三組，統一控制項高度並加入分隔線；佈局按鈕增加文字，保留原 action、輔助使用名稱與預覽隔離。搜尋區可伸縮，工具列內建群組間距為 12 pt，作者 Skin 的 spacing 仍優先。
- 主視窗標題改為 IINA-ANI，側欄及頂層選單改為導覽，固定入口改為顯示主視窗；預覽、編輯器與空頁標題同步移除 Workspace／工作區。新增字串補齊 English、简体中文及繁體中文；內部型別、資料路徑與使用者佈局不改名。
- 實際啟動時發現續看卡片初次載入可能沿用空態高度、呈現壓扁卡片；補上完成佈局後的橫向尺寸重算，隱藏或零高度時保留初始化尺寸，正式高度仍採用實際 clip bounds。未改網格算法、密度或播放流程。
- 驗證：git diff --check、三語新增字串檢查通過；README 指令的 Debug macOS／CODE_SIGNING_ALLOWED=NO 建置成功，Workspace renderer 與 Skin appearance 回歸通過。未修改工程／套件引用，未另跑全新依賴安裝或 manifest 驗證。
- 正式 AppDelegate 實際視窗確認工具列順序、功能選單、活動任務、日曆開啟／Esc 關閉、佈局編輯／取消及導覽選單名稱。最終建置冷啟動直接確認續看卡片完整顯示，再切至設定返回首頁。未套用佈局、Skin 或功能偏好變更；App 留在首頁。
- 截圖與日誌：.build/ui-redesign/toolbar.png、toolbar-build.log、toolbar-renderer.log、toolbar-skin.log。限制：本輪未驗證窄視窗、完整播放／下載、所有自訂 Skin、VoiceOver、最低 macOS／Intel 或正式簽署；日曆顯示既有部分封面更新失敗提示，資料及舊圖仍保留。

## 2026-10-22 — 詳情資訊層級與局部液態玻璃

- 詳情頂部改為圓角資訊區：放大海報與評分，分開作品名稱、原名、類型／年份／集數與評分人數／排名；收藏及快速下載集中於作品資訊，刷新／原始頁面／管理獨立。保留既有 header／list Skin 覆寫入口；內建卡片提供低對比漸層及細邊框，作者背景／裝飾仍優先。
- 選集以較清晰的按鈕間距、目前選擇提示及次要狀態文案呈現；未更新集數、精確身份、已下載標記、來源匹配及自動播放規則不變。資訊分頁靠左排列，簡介、人物、關聯與評論沿用原資料、富文字連結及展開收合。
- 新增 WorkspaceGlassSurface 並註冊工程；macOS 26 起以 NSGlassEffectView.contentView 承載內容，舊系統以 NSVisualEffectView 備援。玻璃限定於來源／下載窗口的標頭與操作區及五狀態收藏選單；降低透明度、增加對比、自訂 Skin 背景／素材有實色備援並觀察設定變更。收藏選單依字級計算高度。
- 快速下載整理為來源、選集及固定底部提交區，顯示已選／就緒數量；來源窗口底部按實際可見按鈕寬度採單列或分行，下載操作列亦依本地化文字自適應。沒有改動已建立下載 owner、去重或取消語義。新增字串齊備 English／简体中文／繁體中文。
- 原始碼／工程檢查：Swift parse、git diff --check、project plist 與新增三語字串檢查通過。README 指令的 Debug macOS／CODE_SIGNING_ALLOWED=NO 最終建置 BUILD SUCCEEDED；沿用既有並行隔離及未使用回傳值警告，不以本次視覺改動擴大處理。
- 回歸：detail episode、Skin appearance、Workspace renderer 三組通過；最後按鈕內距／材質邊框及自適應操作列調整後再次建置並重跑 detail episode 通過。
- 正式 AppDelegate／Workspace 互動：以本次產物冷啟動，確認作品海報、評分、長標題換行；主視窗經系統半屏排列縮到約 960 pt 寬時集數網格重排正常。驗證收藏五個選項／Esc、快速下載開啟關閉、人物／關聯分頁、簡介展開／收合、選集後來源尋找及取消。最終來源窗口顯示已匹配候選並保留明選，未選來源啟播；底部單列按鈕及初始卡片圓角正常。
- 截圖與日誌保留於 .build/detail-redesign/：detail.png、source-popup.png、download-popup.png、build.log 與三組回歸日誌。App 留在原本查看的「学生会也有洞！」詳情頁，搜尋欄為空；未變更外觀偏好或確認收藏狀態，未提交下載。
- 限制：本輪未重驗完整播放／彈幕／下載、淺色與自訂 Skin 全矩陣、系統輔助使用開關切換、完整 VoiceOver、Intel／macOS 13.5。來源／下載窗口分別在原生 640／760 pt 寬檢視；GUI 拖曳未成功改到最小 460／520 pt，不宣稱最小彈窗尺寸實際驗收。既有產品關卡不因此簽收。

### 2026-10-22 — 可調詳情封面轉場

- 新增封面滑動放大、影院推近及光圈揭幕三種效果；曲線均為非勻速。設定 → 外觀與佈局提供效果、曲線、0.2–1.8 秒時長、Gamma 0.35–1 與倍率 1.05–1.5，獨立 Preferences 保存，補齊繁中／簡中／英文。修正小數控制項顯示精度；預設為封面滑入／柔和曲線／0.65 秒。
- 開啟前保存來源封面、實際可見範圍與螢幕座標，詳情先沿用卡片圖，Core Animation 完成時移除覆蓋層並還原封面與焦點。支援 aspect-fill 到 aspect-fit、裁切卡片及 popover 跨視窗座標；影院使用 CIGammaAdjust 真實 Gamma 調整及獨立暗場，光圈使用圓形遮罩配合輕微傾轉。無封面使用淡入；關閉動畫／減少動態效果直接呈現，不疊加 Skin 一般進場動畫。
- 返回／換頁、Escape、縮放、關窗與再次開啟會清理轉場；目的封面必須同視窗且可見。固定產品入口會選中自訂 Layout 的完整巢狀 tab 路徑，不修改作者保存的 Layout。保留開始工作時已存在的其他介面變更。
- 原始碼／工程檢查：新檔已加入 Xcode Sources，git diff --check 通過；本輪未修改 HuyaKit manifest。
- 建置：README Debug macOS 未簽署命令 BUILD SUCCEEDED，最終日誌 `.build/detail-transition-build-final.log`；既有其他模組警告未冒稱清零。
- 回歸：`run-workspace-detail-transition.sh`、`run-workspace-detail-transition-preferences.sh`、`run-workspace-renderer.sh`、`run-workspace-detail-episodes.sh` 均通過。覆蓋真實 AppKit 裁切／座標、fit/fill、自然完成及取消只回呼一次、來源／目的透明度還原、無來源、不同視窗／隱藏目標、巢狀分頁生命週期，以及偏好重開、壞類型、非有限值／上下限與其他偏好不變；Renderer 日誌 `.build/detail-transition-renderer-test.log`。
- 正式 App 驗證：正常退出既有 App，再啟動本份來源 `.build/xcode/Build/Products/Debug/IINA-ANI.app`，走實際 AppDelegate。於 Trends 作品卡實測三種效果並取得過程／完成畫面截圖（本次聊天工具記錄）；完成後詳情與鍵盤焦點可操作。再次重啟確認光圈／1.8 秒設定保留，及 0.65 Gamma／1.18 倍率正確小數顯示。最後恢復預設封面滑入／0.65 秒並實際開啟詳情，App 保持開啟供檢視。
- 限制：本輪未重新驗收真實播放／彈幕／下載、macOS 13.5／Intel、完整 VoiceOver 或系統減少動態效果切換；未改動帳號或收藏。沿用目前使用者 profile 進行 UI 驗證，僅操作上述動畫偏好，未清除資料，未做私人 profile 前後雜湊。既有全面產品驗收與發佈門檻不因此簽收。

## 2026-10-23 — 詳情頁精簡資訊與 Apple TV 式人物排列

- 主頁移除簡介／人物／關聯／評論 segmented tabs 與預設完整資料表，保留作品重點、三行摘要及選集；管理工具收進管理區。章節標題改為可點擊入口，完整簡介、標籤、統計與來源／快取明細移至資訊子頁。
- 新增 WorkspaceDetailShelf：主頁關聯海報優先動畫條目、人物圓形圖片搭配名字與配音／角色，評論置於底部水平卡片。全身人物圖採頂部裁切保留臉部，長標題與配音可顯示兩行；圖片取消、失敗佔位、鍵盤與 Skin 呈現保持獨立。關聯轉場只擷取被點卡片的真實圖片，不誤取佔位圖。
- 詳情內部歷史支援人物清單→人物介紹，以及作品資訊、完整關聯及評論頁；返回、Escape 與 shell 返回優先消費當前可見詳情的內部歷史，回主頁保留垂直與各列水平位置。切頁不重建作品／播放 owner，既有非同步 generation、取消與評論去重／下一頁契約保留。
- 評論卡可點開全文；載入更多保留目前水平位置。完整評論頁仍可載入更多並顯示來源與失敗。補齊 6 個新增字串的英文、簡體及繁體翻譯，更新使用指南及架構說明。
- 原始碼／工程檢查：git diff --check 通過，新 helper 已登記 Xcode Sources；保留工作區既有未提交變更。
- 建置：正式 IINA-ANI Debug scheme（macOS，.build/xcode，不簽署）成功。既有 run-workspace-detail-episodes.sh、run-skin-appearance.sh、run-workspace-renderer.sh、run-workspace-detail-transition.sh 均通過。
- 額外排版檢查：App-linked shelf 檢查 20 張卡片、追加 30 張與縮至 1 張，驗證內容寬、水平位置保留及有效範圍限制；證據 .build/shelf-check/。此檢查不取代正式 App 操作。
- 正式 App 執行：從本次 build 產物啟動 AppDelegate，使用 Bangumi「葬送的芙莉蓮」驗證精簡主頁、人物橫列與完整網格、人物介紹、兩層 Escape、工具列返回、完整關聯頁、評論全文及完整評論清單。以原生水平捲軸移至中段，再載入更多，確認新評論追加且畫面位置保留；1280 pt 與約 960 pt 寬視窗皆完成目視檢查，已還原視窗大小及清空驗收搜尋字串。截圖／建置／回歸記錄在 .build/detail-shelves/。
- 限制：本次未重跑實際播放、下載、收藏寫入或 OAuth 同步，不宣稱最低 macOS／Intel 驗收；觸控板完整手勢矩陣及所有作者 Skin 未重跑。原生捲軸操作可水平瀏覽，CUA 的合成水平滾輪未產生可確認位移，未將其列為手勢通過證據。

## 2026-10-23 — 頂部資訊預覽與管理彈窗

- 作品資訊移入 hero 右欄，主內容保留海報、名稱、評分與操作；依內容寬度在窄視窗改為同卡片內縱排。新增 WorkspaceDetailInfoPreview 並登記 Xcode Sources：先合併預覽空白，再保留最多 180 個 Unicode Character／七行，TextKit 對最後可見行做文字 alpha 漸淡，獨立箭頭開啟未刪減的資訊子頁；完整原文與來源不變。
- Manage 由內嵌展開區改為獨立可縮放 NSPanel，玻璃標頭與固定關閉區沿用 WorkspaceGlassSurface；原分類、網址、Bangumi 關聯、刷新與資料狀態欄位重用，狀態文字即時同步。重開不重置同作品未提交的分類與 ID，背景同 ID 更新不覆寫草稿。關閉／Escape 結束編輯並還原焦點，不取消已提交操作；reset／detach／資訊頁與來源窗口切換會關閉管理窗口。
- 文件與語系：新增兩個標籤的英文／簡體／繁體翻譯，更新使用指南及架構描述；保留工作區既有變更。git diff --check、字串 JSON 與工程 Sources 註冊檢查通過，未變更 HuyaKit manifest。
- 建置與回歸：README Debug macOS 未簽署建置成功。detail episode、Skin appearance、Workspace renderer 回歸通過；InfoPreview 離線檢查覆蓋 Unicode、180 字界線、七行、寬窄高度、空白正規化及實際 glyph alpha 淡出。建置／回歸記錄位於 .build/detail-info-popup/，預覽檢查位於 .build/info-preview-check/。
- 正式 App 驗證：從本次 build 產物啟動實際 AppDelegate，以「FX战士久留美」檢查 1280 pt 右欄與約 1192 pt 縱排，最終版沒有多餘空行；箭頭可打開全文，Escape 返回並恢復焦點。管理窗口開關、Escape、未提交網址／分類／ID 重開保留、無效 ID 本地驗證即時提示均確認；沒有提交有效 ID 關聯或分類寫入。測試欄位已還原、搜尋字串清空、視窗尺寸恢復，App 留在作品詳情頁。截圖 detail-final.png、narrow-final.png、manage-popup.png。
- 限制：本輪未重驗播放／彈幕／下載或實際收藏／關聯寫入，未實測完整 VoiceOver、所有 Skin、系統輔助使用切換及最低 macOS／Intel。既有 Bangumi 未登入提示仍如實保留，未改帳號、收藏或作品關聯。
