# iOS CSS1 來源排查（2026-10-30）

> 2026-11-03 模組更新：兩端已改為依賴本機 [SourceCore](../../SourceCore/README.md) 套件，共用來源身份、能力、配置驗證、訂閱規則與公開播放器協議；不再直接把來源核心檔案編入兩個 App，也不使用 `MOBILE_SOURCES` 切換核心錯誤。以下日期標記的站點能力與差異是原次檢查快照；套件抽取沒有移植其餘平台專屬解析器。此次驗證見[工作記錄](../history/WORK_LOG.md)。

> 範圍更正：首兩輪為 iOS CSS1 解析器驗證，macOS 當時只有建置／視窗冒煙測試，不能據此宣稱 macOS 來源已修復。macOS 實際修復與驗證請看下方「macOS 路徑更正」。

本次以目前 `https://sub.creamycake.org/v1/css1.json` 的 20 筆條目為範圍：18 筆可轉換成靜態頁配置，2 筆在配置階段不支援。使用正式 MobileSourceClient 搜尋「海贼王」，無結果才搜尋「鬼灭之刃」；每站最多兩個結果、各前三條線路的第一個集數連結。這是抽樣相容性檢查，不代表同名作品配對正確、全站可用或所有集數可播。

原訂閱與測試用遷移配置分開記錄。2k、嘀嗒、熱播的新網域僅在隔離測試配置使用，未自動覆寫使用者配置。HTTP 狀態會隨站點、網路及時間改變。

## 逐項結果

| 來源 | 確認的階段／原因 | 修正或目前狀態 |
|---|---|---|
| 稀飯動漫（首輪） | 播放頁已有 MP4，但地址指定 `8088` 連接埠，被既有來源網址契約拒絕 | 顯示連接埠不支援；不是 MP4 編碼問題，未刪除連接埠或放寬任意目的地 |
| girigiri 愛動漫 | 解析到 MP4 | 原有路徑成功，本輪只驗證網址解析 |
| 2k 動漫 | 原訂閱搜尋轉址到未宣告的 `www.mutedm.com`；隔離遷移配置的播放資料為 `encrypt=3` | 分別顯示轉址與未支援加密；尚未實作該加密協議 |
| 嘀嗒影視 | 原訂閱搜尋轉址到未宣告的 `www.didahd.xyz`；隔離遷移後抽樣線路為 `encrypt=3` | 同上；桌面專屬動態解析器不等於 iOS 靜態解析能力 |
| 叽哔動漫 | 解析到 m3u8 | 原有路徑成功，本輪只驗證網址解析 |
| E-ACG | 搜尋 HTTP 403；獨立回應檢查為 Cloudflare challenge | 顯示 HTTP 403，未取得影片格式或編碼資料 |
| 森之屋動漫 | 同站公開 API 解析到 m3u8 | 原有路徑成功，本輪只驗證網址解析 |
| 風車影視 | HTTP 200 但內容是「系統安全驗證」，含 `/ajax/verify_check.html` 表單 | 修正成網站驗證錯誤，避免誤報搜尋無結果 |
| 去看吧 | 搜尋 HTTP 403；獨立回應檢查為 Cloudflare challenge | 顯示 HTTP 403，未取得影片格式或編碼資料 |
| 海星動漫 | 一個目錄樣本沒有可用集數；另一個播放頁需 iframe／額外播放協議 | 分別顯示目錄規則／集數連結問題、間接播放器；尚未移植其站點協議 |
| 櫻花動漫 | MacCMS 宣告 `encrypt=0`，但 url 值是播放識別碼而非媒體網址 | 顯示仍需進一步解析；不把識別碼當加密格式或媒體副檔名 |
| 嘀哩嘀哩 | 廣泛目錄選擇器包含分頁／空導覽群組；播放器需同站 `_get_play` API | 已修正 DOM 配對及空群組處理，按所選頁面的第一個 play_id 解析並核對回應 ID；真網取得 m3u8，FFmpeg 第 10 秒成功解碼 |
| 新優酷 | 搜尋 HTTP 403；獨立回應檢查為 Cloudflare challenge | 顯示 HTTP 403，未取得影片格式或編碼資料 |
| 番茄動漫 | 解析到 m3u8 | 原有路徑成功，本輪只驗證網址解析 |
| Hanime1 1080p | 頁面同時提供 480／720／1080 MP4，原程式視為地址歧義 | 保留訂閱畫質，以 HTML5 source 的 size 選取 1080；真網解析成功，未解碼或播放 |
| Hanime1 720p | 同上 | 明確選取 720；真網解析成功，未解碼或播放 |
| wedm | 解析到 m3u8 | 原有路徑成功，本輪只驗證網址解析 |
| 熱播之家 | 原訂閱搜尋轉址到未宣告的 `www.rebozj.cc`；隔離遷移後抽樣為 `encrypt=3` | 分別顯示轉址與未支援加密，未自動改網域 |
| 稀飯動漫 Next | 配置使用尚未支援的 `json-api` factory | 配置階段略過並保留原因，沒有進入影片格式檢測 |
| 影視森林 | 訂閱入口為 HTTP | 配置階段略過，未進入影片格式檢測 |

修正後共有 **8 個來源配置**取得樣本媒體網址，包含兩個 Hanime1 畫質配置。只有本次嘀哩嘀哩額外做第 10 秒畫面解碼，目視為帶廣告的片頭；不能據此宣稱 8 個來源均已完成播放、音訊或完整正片驗收。Hanime1 先前曾回 403，本次網路抽測可取得頁面，兩種結果均只代表當時請求。

## 錯誤與相容性變更

- 原 `unsupportedResponse` 不再包辦 CSS1 的搜尋結構、目錄結構、播放器資料、未知加密、間接播放地址、媒體副檔名、網址規則、連接埠、多地址歧義、畫質缺失及空／過大解析內容。
- HTTP 401 與 403 分開；未跟隨的轉址另行顯示。已識別的 HTML 驗證頁不當作空搜尋結果。
- CSS1 匯入探測保留最後一個選集／解析錯誤，不再全部吞成「沒有樣本媒體」。多個作品／線路可能各有不同失敗，此提示不代表所有失敗均相同；逐次樣本證據另存於本機報告。
- `defaultResolution` 保存成可選的 `webSelector.preferredVideoHeight`。既有 v3 配置缺少此欄位仍可讀取；重新匯入後才有指定畫質。帶 size 的 HTML5 多畫質來源必須存在指定畫質；不自動降級。無畫質標記的其他來源仍依原直接網址解析規則處理。
- 不執行遠端 JavaScript，不猜測 `encrypt=3` 的演算法，不繞過網站驗證，也不以忽略格式／網址檢查換取成功。

## 證據與驗證

忽略目錄 `.build/css1-diagnosis/` 保存完整逐次脫敏結果：`final-live.json` 是原訂閱 18 站測試；`offline.json` 是保存頁面的中途分類重現；`dilidili-verified.json` 與 `quality-verified.json` 是後續修正驗證。中途檔案代表當時程式，以上表格整合最後結果。記錄僅含來源、階段、錯誤類別及媒體網域／副檔名，不列 Cookie 或完整簽名媒體 URL。

離線回歸包含 DOM 名稱／連結配對、分頁排除、公開 API 精確 ID、各錯誤分類、匯入原因保留、畫質保存／重載／選取／缺失、原生配置相容、取消與映射契約。正式 App UI 用受控 transport 驗證 HTTP 403 與未支援加密提示；這與真網來源抽測是不同證據。詳細建置與 UI 結果見[工作記錄](../history/WORK_LOG.md)。


## 2026-10-30 第二輪：網域遷移與播放器協議

上述表格保留首輪診斷快照；本節為後續修復結果。使用未改網域的原訂閱配置，經正式 `MobileSourceClient` 抽測搜尋、目錄、所選集數解析，再以 FFmpeg 讀取媒體並解碼一幀；這不代表所有影片或完整 App 播放流程均已通過。

| 來源 | 本次修復 | 真網結果及剩餘限制 |
| --- | --- | --- |
| 2k 動漫 | 限定舊站轉址至 mutedm；接入 m2 的 index → dp 播放器，驗證集數／線路與原 token，正確抽取含巢狀物件的配置 | 「海賊王：紅髮歌姬」m2 線路取得 MP4，FFmpeg 解碼成功；r2 的外部解析服務抽查 HTTP 404，未宣稱支援 |
| 嘀嗒影視 | 限定轉址至 didahd.xyz；辨識各線路 artplayer、呼叫其公開 API、按 timestamp 解密 AES-CBC | 「海賊王（真人版）第二季」超清 B 第 1 集取得 MP4，FFmpeg 解碼成功；BD1 返回相對 PHP 解析入口，仍需額外協議；超清 G 的無副檔名 MP4 已補上指定 CDN 檔頭檢查並成功解碼 |
| 熱播之家 | 限定轉址至 rebozj.cc；同一公開 artplayer 協議 | 同作品藍光 B 第 1 集取得 MP4，FFmpeg 解碼成功；藍光 G 同類無副檔名地址已通過檔頭檢查與解碼，仍非每條線路都可用 |
| 稀飯動漫 | 僅放行其已知 HTTPS 媒體主機 8088；依 playerconfig 讀取所選線路官方二級播放器，接入 UID AES 協議 | 8088 直連仍 TLS 失敗；兩個作品的二級播放器均返回 code 101。現在明確報告播放器服務無法解析，不再誤報 MP4 格式或本機連接埠限制；上游故障無法在本機修好 |

`encrypt=3` 是播放器網址處理方式標記，不是影片封裝格式或 DRM 的證據。成功樣本為 MP4；另有 byteimg CDN 用 `.image` 路徑提供 MP4，另確認 cmecloud 指定主機的無副檔名地址也是 MP4。新增限定主機／查詢標記與 `ftyp` 檔頭驗證，沒有對所有副檔名放行。

協議請求不攜帶帳號 Cookie，不執行遠端 JS；來源、線路與集數綁定不變。新增 `playerServiceUnavailable` 英文／簡中／繁中提示；未知站點或線路仍回報未支援的加密協議；返回相對解析入口時顯示仍需進一步解析。

驗證：`Tests/run-ios-sources.sh`（包含獨立 AES 向量、錯誤密文、巢狀播放器配置、token 篡改、轉址／連接埠邊界、二級播放器成功與 code 101）、`Tests/run-multiplatform-contracts.sh` 通過；iOS 正式 App 的來源錯誤與配置匯入兩項 UI 測試通過，另重跑錯誤測試驗證新增服務失敗提示（共三種錯誤，含截圖）；macOS Debug 建置、正式 App 啟動及搜尋視窗導覽通過並截圖。本輪沒有驗證長時間播放、音訊、彈幕、多視窗播放及最低 OS 版本。

本機證據：`.build/css1-diagnosis/{protocol-final.json,protocol-g-lines.json}`、`.build/source-protocol-fix/{final-live.log,g-live.log,tests.log,contracts.log,ios-ui.log,ios-service-ui.log,ios-final-build.log,mac-build.log,mac-app.png}`。報告不保存完整簽名媒體 URL；建置與抓取暫存不納入版本控制。


## 2026-10-30 macOS 路徑更正（使用者回報後）

前述「修復」主要落在 iOS CSS1 路徑，不能套用至 macOS。確認 iOS 的 SourceFixtures 受 `#if DEBUG` 與明確啟動參數保護；macOS 不編譯該測試注入，未發現測試資料替代正式解碼。macOS 原本使用 Didahd／Rebo／XiFan 原生 actor；2k 尚無 macOS 原生適配器。

本次把公開播放器協議搬到共用 `PublicPlayerProtocol.swift`，由 macOS 正式解碼器呼叫：嘀嗒新增 BBA／NBY／rrmj 線路並保留 4kvm 與其代理；熱播改用固定協議解密，移除已不用的隱藏 WKWebView 解析器。稀飯 code 101 改報播放器服務失敗。macOS 補上相關三語錯誤，避免所有原因落入泛化格式錯誤。

直接連結本次 macOS App 二進位，透過原生 episodeList／decodeUrl 真網抽測：嘀嗒及熱播 `1164-6-1` 的 G 線路均成功解碼一幀；`1164-12-1` 的 B 線路雖可解析，但本次媒體解碼失敗（FFmpeg exit 196），不得宣稱已可播放。此處作品為網站目前的「海賊王真人版」，不同於先前 iOS 抽樣搜尋命中的第二季。

正式 App 曾在已解析 G 線路交接至 IINA 外掛時停留在本機佔位媒體黑畫面。因此嘀嗒／熱播在未啟用彈幕的播放請求改用 IINA 原生媒體 URL 交接；需要彈幕的外掛協議保持原路徑。回歸新增直接 URL 交接斷言。


正式視窗驗收結果：重新建置並重啟 `.build/xcode/Build/Products/Debug/IINA-ANI.app`，經 Open URL 開啟嘀嗒 `1164-6-1`、選取超清 G 第一集、按播放，IINA 顯示實際影片畫面；其後暫停時顯示 `00:50 / 1:04:25`。截圖 `.build/mac-source-fix/iina-playing.png`。這是正式 App 真網播放證據，不是 fixture 或隔離 FFmpeg 畫面；尚未完成長時間播放、音訊聽測、熱播正式視窗、彈幕與全部集數驗收。

本輪 macOS／iOS 建置、`run-ios-sources.sh`、`run-w3-sources.sh`、`run-dependency-regression.sh --unit` 通過。相關紀錄為 `.build/mac-source-fix/{build-final.log,ios-build.log,ios-regression.log,regression.log,playback-tests.log,live.log}`。2k macOS、B 線路媒體讀取、稀飯上游故障仍未完成，不能以先前 iOS 結果替代。


## 2026-10-30 macOS 後續：2k 原生接入與 B/G 重驗

- 新增 `Mutedm` 原生適配器及來源註冊，支援舊／新網域、`voddetail`／`vodplay` 身分、逐線目錄及精確集數解析，使用與 iOS 共用的 m2 協議。影片網址不依賴測試注入；非 m2 線路回報協議未支援，不自動切換。
- CSS1 搜尋轉換新增限定 2k JSON 格式；保持訂閱預覽／套用流程，既有快照不被自動改寫。離線測試涵蓋未知主機、錯誤集數、憑證網址、目錄配對、JSON 規則轉換與套用，以及 IINA 原生交接。真網原生搜尋「海賊王」返回 1 個作品。
- 連結最新 macOS 二進位，對嘀嗒／熱播 `1164-6-1`（G）、`1164-12-1`（B）、2k `1932-3-1`（網頁專線）逐一呼叫原生目錄與解碼器：全部返回 HTTP 206、MP4 `ftyp` 檔頭，FFmpeg 解碼成功。B 線路較早的失敗保留作歷史；本次重新取得媒體已可讀，沒有證據把前次失敗定為格式問題。首次重驗曾遇 artplayer 網路錯誤，後續請求成功，不宣稱上游永遠穩定。
- 稀飯原生解析仍回報 `playerServiceUnavailable`；8088 原始直連再次 TLS 失敗（curl exit 35，HTTP 000）。沒有關閉 TLS 驗證或宣稱修復上游。
- 證據：`.build/mac-source-next/live-final.log`（不記錄簽名媒體 URL）、`regression-final.log`、`playback-tests.log`、`ios-regression.log`、`build-final.log`、`ios-build.log`。macOS／iOS 建置、來源與播放回歸均通過。

- 正式 App 驗收：重新啟動最新 macOS 產物，由「開啟網址」輸入舊網域 `https://www.2kdm.com/vodplay/1932-3-1.html`，確認目錄後選網頁專線，原生解碼成功並交給 IINA。看到實際《紅髮歌姬》影片畫面，暫停時顯示 `01:26 / 1:55:05`；截圖 `.build/mac-source-next/2k-playing.png`。未驗整片／音訊聽測／彈幕／所有作品／APP 專線；未改播放器偏好或清除使用者資料。

## macOS 稀飯與 2k APP 專線再驗（2026-10-30）

- 稀飯公開 EcPlayer1.js 明確將 `code=103` 定義為「未匹配到接口地址返回原地址」，不是解析錯誤；macOS 現在與 `200` 一樣按回應 UID 解密。取得地址後進行限時、有限前綴的 HTTP 檢查，分開顯示缺少有效期簽名（401 / expire missing）、403、404／410；不將 HTML 錯誤頁交給播放器。
- 新番 3541、3462、3500 等主線①抽查均為 apn.moedot.net 的 MP4 地址，播放器 code103，媒體端缺少簽名；主線②抽查為 code101。這些不是副檔名或 AES 算法錯誤，沒有在用戶端臆造簽名。舊番 1086 的 8088 地址仍 TLS 失敗（curl 35 / HTTP000），未停用憑證驗證或刪除連接埠。
- 稀飯 3541 第01集「備用①」code200，媒體 HTTP206，FFmpeg 解碼成功；正式 App → 明確選取備用① → IINA 實際影片畫面到 00:21 / 23:40。無彈幕時改用原生直接媒體交接，保留彈幕交接分支。截圖 `.build/mac-remaining/xifan-playing.png`。主線①在正式 App 顯示缺少簽名的具體提示，截圖 `xifan-signature-error.png`。
- 更正先前 2k APP 專線的判斷：r2 的 playerconfig `ps=0`，不使用殘留的 muiplayer parse 地址。實際 r2.js 載入 appzx.html，內容明示「APP专线仅提供APP内部播放」。macOS 改為明確提示選擇網頁專線，不再誤報 encrypt=3 不支援；沒有把 APP token 投到網頁接口或自動切換線路。
- 2k 正式 App 驗收：APP 專線顯示專用限制提示且播放按鈕不可用；手動選擇網頁專線後 IINA 播放至 00:19 / 1:55:05。證據 `.build/mac-remaining/2k-app-only.png`、`2k-web-playing.png`。本輪不能宣稱 APP 專線已可播放。

## macOS 8088 相容處理與官方 APP 協議研究（2026-10-30）

### 稀飯

- 同一個舊番 1086/1/1 的 `play.xfvod.pro:8088` 在 TLS 握手完成前斷線：curl 預設、TLS 1.2 與 HTTP/1.1 測試均為 HTTP000／curl35；OpenSSL 顯示 unexpected EOF。HTTP 明文連線亦無有效回應。這不能歸因為影片編碼或憑證信任問題。
- 新發現：該主機標準 HTTPS 埠的**原路徑與原查詢參數**可讀取 MP4，TLS 正常校驗、HTTP200，檔頭為 ISO BMFF `ftyp`，FFmpeg 解碼成功。macOS 增加限定相容處理：只接受 HTTPS、精確主機 `play.xfvod.pro`、原埠8088、MP4、無憑證與 fragment；使用標準 HTTPS 端點前讀取最多64 bytes，驗證最終網址未變更及實際檔頭。失敗保留錯誤，不切到其他來源／集數；沒有停用 TLS 校驗。
- 正式 App 新建置實播 `https://dm1.xfdm.pro/watch/1086/1/1.html` 的舊番主線①第01集，IINA 顯示實際畫面並到達 **00:14 / 24:45** 後暫停。證據 `.build/mac-protocol-research/xifan-old-main-playing.png`。
- 新番主線①的 `xfdm2` 公開入口重驗仍回 code103；公開 JS 定義為「未匹配到接口地址返回原地址」。原地址仍缺少有效期簽名，媒體端401。沒有在公開頁面、播放器 JS 或入口轉址發現可用的簽名取得請求，因此此分支未修成可播。

### 2k 官方 APP

- 官方網站 `/index.php/label/down.html` 連往 `lmman.com`；下載頁透過 `release-config.json` 公布 APK `app-arm64-v8a-release-1.1.0-3.apk`。僅靜態檢查 APK 內 Flutter AOT 字串，沒有安裝／執行 APK 或加入下載程式到正式產品。
- APK 公開使用 `api.lmman.top`；確認流程為 `GET /api/v1/anime?q=<title>` → `GET /api/v1/anime/<app-id>` → `POST /api/v1/anime/<app-id>/playback`，播放欄位為 `source_key`、`episode_key`。APP 與網站作品 ID 不同，網站1932對應 APP987才是同名2022年的《海贼王：红发歌姬》；直接套用1932會取得另一部作品。
- 同名同年份劇場版的官方 APP 播放 API 回 **11520 / READ_ACCESS_REQUIRED：需要观看激励广告或开通会员**，未返回媒體網址。目錄 `requires_login=false` 不代表已有播放權限。故 APP 專線仍未實播成功；現有 macOS 限制提示保留。這是已確認的服務端觀看授權要求，不能再標為單純 encrypt=3 或網頁轉址問題。
- 研究證據摘要（不含 token／完整簽名媒體網址）：`.build/mac-protocol-research/app-research-evidence.json`。尚未接入官方 APP 帳號／廣告／會員流程。
- 邊界：以上為官網目前推薦的新版 APP 流程；尚未建立舊網頁 r2 密文與新版 API 集數 key 的直接對應，不能聲稱已完成 r2 解密。11520 是新版官方 APP 同作品樣本的實際回應，未推論所有歷史 APP／線路都使用同一授權機制。

## macOS 稀飯新站簽發協議與 2k 舊版 APK（2026-10-30）

- 稀飯研究線索來自[公開適配記錄](https://github.com/AlcMaple/tools/blob/main/docs/ideas/011-%E5%9C%A8%E7%BA%BF%E8%A7%82%E7%9C%8B.md)，再以本輪 `next.xifanacg.com` 的公開頁面、客戶端 bundle、實際 API 回應獨立核對。新站從 Flight JSON 提供作品、獨立劇集 ID 及穩定線路 ID，透過 `api.xifanacg.com/functions/v1/issue-web-playback` 的 fallback 動作和 episode_id／source_id 取得限時網址。
- 已實作 macOS 原生新站網址、目錄及簽發。回應須核對 anime_id、episode_id，且候選中所選 source_id 的 URL 必須等於返回 URL；不接受其他線路代替。新站媒體有 sign 參數；每次解析重新簽發，不保存完整簽名地址。網域只精確接受 next.xifanacg.com，與舊站 dm1.xfdm.pro 的路由／身份分開，舊集數不重新編號。新增目錄 ID 使用 next 命名空間，避免與舊書籤混用。
- 初次 URLSession 探測帶舊 player.moedot.net Referer，雲端轉址回 HTTP400；移除 Referer 後 HTTP206 並讀到 ftyp，確認不是 URLSession 本身不支援。新站探測使用無 Referer 的有界讀取；IINA 無彈幕直接媒體交接也移除殘留的外掛 JSON Referer。舊地址的401與舊番8088探測保留。舊缺簽名訊息改為指引至新站重新確認作品／集數，三語同步。
- 新站直接網址已支援；訂閱搜尋仍可能返回舊站，未自動遷移訂閱或舊映射，不能據此宣稱舊站缺簽名地址已恢復。
- 2k 舊版：取得歷史鏡像的 com.zcj.mutefun 3.5.0，MD5 與多個歷史下載頁一致（224cfcf8e48ca06821f069be016053ef），但沒有可獨立核對的官方歷史簽章。僅解壓及靜態分析；Flutter runtime 為 Dart2.19.6，AOT 有混淆，發現 /v1/parsing/proxy、/v1/config/get、ConfigParseListModel、HttpClient.encryptDecodeInInterceptor 等字串線索。
- 尚未從舊版還原可驗證的服務端基址、解析配置、r2 明文或完整請求；不能宣稱上述字串等於已證實呼叫鏈。沒有把新版 APP 的11520授權回應套用成舊版結論，沒有加入猜測的 r2 解密器。舊 APP 專線仍未實播成功。
- 正式 App 驗收：最終 Debug 產物開啟 `https://next.xifanacg.com/anime/3441/play/203869?source=xfxf1`，明確選主線①「警长对曼登·提姆的要求」，由新站 API 重新簽發，再經現有 IINA CLI 作完整參數交接。實際影片畫面已出現，時間從10.59秒推進到12.43秒／總長1516.159秒（25:16），暫停狀態已確認。截圖 `.build/mac-signature-research/new-main-playing.png`，唯讀 IPC 證據 `real-playback-state.json`；未將完整簽名媒體網址納入報告。
- 播放限制：本次雲端媒體約40KB/s、頻繁緩衝。這是短時間實播與時間推進驗證，不是流暢／整集驗收。URL scheme 多次未成功；CLI 交接在本輪正式 App 成功，尚未將每個 IINA 內部差異獨立歸因。
- 最終播放交接只針對稀飯新站調整，不改其他來源的既有外掛中繼資料。iOS 本輪未加入新站解析能力。

## macOS／iOS 解析模組差異檢查（2026-10-30）

本節為目前工作目錄的原始碼與 Xcode 工程比對，沒有重新請求來源、重建或實播。未修改解析程式。

### 共用範圍與入口

兩個工程都編譯同一份 SourceConfiguration、SourceSelection、SourceCapabilities、SourceSubscriptionRules、PublicPlayerProtocol。共用配置／身份／能力與部分協議，並非共用所有站點解析器。

macOS 經 SourceRegistry → VideoDecoder → 原生站點 actor 或 ConfiguredSource。CSS1 訂閱轉換器只轉搜尋規則，播放與驗證仍由本地適配器負責。iOS 經 MobileSourceLibrary → MobileSourceClient → MobileCSS1Client／宣告式解析；CSS1 會轉成完整 v3 web-selector 配置。SourceConfiguration.effectiveCapabilities 明確將 web-selector 配置限定在 iOS，故同份 v3 配置不能直接當作 macOS 播放器使用。iOS 預設來源庫為空，正式來源依使用者匯入／啟用決定。

| 項目 | macOS 實作 | iOS 實作／影響 |
|---|---|---|
| 稀飯新站 | XiFan.swift 內含新網址、Flight 目錄、issue-web-playback 及回應身份核對 | 沒有對應的新站解析入口或簽發請求，尚未同步 |
| 稀飯舊8088 | XiFan.legacyHTTPSMedia 限定主機／埠／MP4，驗證標準HTTPS原路徑後使用 | 只在部分8088播放資料走共用舊ec.php；雖允許該媒體埠，沒有標準HTTPS相容處理 |
| 稀飯code103 | 桌面XiFan.resolvedMedia接受200與103 | 共用PublicPlayerProtocol.resolveXiFan仍只接受200；其請求白名單也只接受xfdm1／from=cf |
| 稀飯無簽名原地址 | 桌面會探測HTTP並區分缺簽名；新站另行簽發 | 非8088的encrypt=0通常直接按副檔名接受，可能直到mpv播放才失敗，沒有相同的簽發／探測分支 |
| 2k網頁m2、嘀嗒／熱播ArtPlayer | 原生目錄／站點驗證後呼叫PublicPlayerProtocol | CSS1目錄／站點驗證後呼叫同份PublicPlayerProtocol；timestamp AES、SmartPlay、m2流程及特定CDN檔頭探測已共用 |
| 2k APP r2 | Mutedm.payload明確拋appOnlyPlayback | 共用resolve沒有r2分支，最後拋unsupportedEncryption；兩端都沒有完成r2解密，但錯誤原因不同 |
| 嘀嗒4kvm | 專用WKWebView攔截及DidahdProxy | CSS1流程不執行下載的JS，沒有對應4kvm適配器 |
| 嘀哩嘀哩_get_play | 原生解析逐個button取得多條可用線路 | CSS1分支只解析頁面第一個play_id，避免暗換線，線路覆蓋不相同 |
| 播放交接 | 外部IINA／mpv；稀飯新站另有CLI與Referer處理 | 內嵌MPVEngine，直接loadfile；沒有IINA交接層 |

### 錯誤與測試差異

- 錯誤列舉與部分文案已共用／同步，實際拋出點尚未對齊。appOnlyPlayback、mediaSignatureMissing、mediaNotFound在iOS有文案，不能據此認為相同解析分支已實作；一般HTTP404在iOS傳輸層仍歸為unsupportedResponse。
- macOS部分原生站點仍拋VideoGetError，會合併到較一般的unsupportedResponse；iOS多由MobileSourceClient.failure與CSS1分階段錯誤轉換。不能僅比較畫面文字判斷兩端故障相同。
- 桌面DesktopPlayerRegression覆蓋新站Flight／簽發身份、103、8088相容與r2提示；iOS CSS1ProtocolRegression主要覆蓋較早的共用協議。缺少同輸入、同媒體結果／同錯誤分類的跨平台等價測試。
- iOS SourceFixtures僅在DEBUG且明確fixture啟動參數下使用；普通啟動不會因此取得測試影片。這與上述解析功能未同步分開看待。

建議優先把稀飯的新站目錄／簽發與舊站回應判斷移到可供兩端使用的核心，再同步r2診斷與契約測試；帳號、傳輸、IINA／內嵌mpv及UI仍保留各自平台處理。來源可解析與影片流暢播放仍須分別驗收。
