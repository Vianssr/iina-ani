# IINA-ANI iOS 簡化版

獨立的 SwiftUI iPhone／iPad App，宣告最低 iOS 17。工程位於 `iOS/ANI.xcodeproj`，scheme 為 `ANI`；透過 Swift Package Manager 固定版本的 MPVKit 嵌入 libmpv／FFmpeg；不需要安裝外部 IINA／mpv App，不連結桌面版 HuyaKit 或 Torrent 核心。首次建置會下載二進位 XCFramework，依賴與授權見 [iOS 播放核心](../iOS/THIRD_PARTY.md)。

兩端透過本機 Swift Package [SourceCore](../SourceCore/README.md) 共用來源身份、配置驗證與公開播放器協議。新增 `SourceRuntime` 產品供 iOS 使用從桌面移植的來源解析與 HTTP，兩端亦共用 CSS1 搜尋訂閱轉換／下載政策；桌面原有站點帳號及播放器整合保留。

## 五個入口

- **探索**：顯示 Bangumi 本週日曆（當天優先），搜尋番劇、載入更多結果、查看作品詳情與原始 Bangumi 頁面。載入失敗可重試，下拉可重新整理；刷新完成前保留既有內容，失敗時也不清空。切換搜尋時不會混入上一個請求的結果。
- **Trending（熱門）**：依 Bangumi 收藏熱度排列番劇，切換本季或全部時間，可載入更多、重新整理並開啟作品詳情。這是收藏熱度排序，不代表播放量。
- **Calendar（放送日曆）**：按週一至週日瀏覽放送作品，預設選今天；日期代表 Bangumi 排期，不保證來源已更新。
- **收藏**：詳情的收藏按鈕只加入／移除收藏；「觀看分類」獨立選擇想看、在看、已看、擱置、丟棄或未分類，不會自動收藏。收藏頁可按中文／原文名稱搜尋、按分類篩選，並按最近收藏、名稱或評分排序；排序只改變畫面，不重寫收藏順序。收藏與分類跨重啟保存，移除收藏不清除分類或快取。工具選單另有「Bangumi 帳號與同步」及獨立「連結收藏」。
- **播放**：貼上 HTTPS 影片／HLS 直連、從系統「檔案」選擇影片，或進入 BT 播放連接自己的 TorrServer。使用內建 mpv 播放器；支援多選影片建立播放清單，完成後銷毀核心再釋放檔案存取權。

首次使用即有 17 個經審核的 CSS1 對應來源，預設不啟用，也不會自動下載訂閱。探索和播放頁右上角可開啟「片源設定」；匯入網址預填 `https://sub.creamycake.org/v1/css1.json`，主動下載、預覽並套用後，才啟用內建來源的搜尋規則。來源本身仍需手動啟用。也可輸入其他公開 HTTPS 訂閱網址，匯入通用靜態來源；完整配置 JSON／清單可另外匯入。舊行動 v3 `webSelector` 配置與不相容搜尋覆寫只保留資料並標示未啟用，不再使用舊解析器，也不按名稱或網域猜測遷移播放映射。

提供繁體中文、簡體中文與英文，跟隨系統 App 語言。主工作區使用頂部小標題，直接呈現搜尋、日期選擇、番劇或播放操作，移除宣傳區塊及重複說明；保留系統字級與明暗外觀，播放器使用深色介面。

## 建置與安裝

用 Xcode 開啟 `iOS/ANI.xcodeproj`，選擇 `ANI` 與 iPhone 模擬器後執行。實機需在 Signing & Capabilities 選擇自己的開發團隊及可用 Bundle ID；目前 Bundle ID 為 `com.LlS.iina-ani.ios`，版本 `0.1.0`。

```sh
xcodebuild -project iOS/ANI.xcodeproj -scheme ANI \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .build/ios CODE_SIGNING_ALLOWED=NO build
```

上述未簽名命令可檢查編譯，但不能用來驗收 Keychain 登入。要在 Simulator 操作帳號，改用 `CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=-` 的 ad-hoc 簽名；不需要把權杖改存明文或關閉安全儲存。實機仍需有效開發簽署。

不提供已簽署 IPA 或 TestFlight 發佈。宣告最低版本不代表已驗證 iOS 17 實機。

## 驗證

```sh
swift test --package-path SourceCore --scratch-path .build/source-core
bash Tests/run-ios.sh
bash Tests/run-ios-catalog.sh
bash Tests/run-ios-sources.sh
bash Tests/run-ios-bt.sh
xcodebuild -project iOS/ANI.xcodeproj -scheme ANI \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' \
  -derivedDataPath .build/ios -parallel-testing-enabled NO test
```

第一項在 macOS 執行資料與儲存回歸，包含舊檔／v1／v2 升級、映射保存／移除、原順序與身份保留、分類與收藏獨立、寫入失敗回滾、壞檔／未知版本保護、資訊快取，以及帳號切換、待同步重試、舊回應與完整遠端匯入；不等於 iOS 執行驗收。第二項在模擬器操作正式 App，部分既有案例依賴 Bangumi 與 Apple 公開 HLS 測試串流；裝置名稱須依本機環境調整。

M5 基礎對齊驗收已完成：iPhone／iPad 模擬器與授權 iPhone 17 實機（iOS 27.0.1）完成正式 App 真實來源旅程；實機以隔離開發簽署安裝，未覆寫原 App。來源 fixture、實際 libmpv 解碼、真實網站搜尋／解析／串流／重啟續播、VoiceOver 語音及使用者手動操作分開記錄，公開 HLS 直連不能代替配置來源。結果及自動化逾時／人工觀察界線見[跨平台規劃](planning/MULTIPLATFORM_BASELINE.md)；最低 iOS 17、iPad 實機運行與完整輔助使用矩陣仍未驗證，開發簽署不等於 TestFlight／正式發佈。

## 範圍與資料

這是行動端功能集，不是桌面功能的完整移植。Bangumi 提供資訊，不提供影片；探索與收藏的詳情頁提供選集與尋源，需啟用已配置來源。可信且唯一的候選可自動確認；其他情況仍須選擇並確認來源作品與集數。探索與播放頁提供本機觀看歷史及續播，播放器可手動或自然播完後接續同源下一集。M6 已接入收藏分類同步、詳情補充資訊、搜尋訂閱、有限自動彈幕及連結收藏。其他桌面專屬解析器、站點登入、下載、本機 BT 引擎、桌面外掛與 Skin／Layout 尚未移植；BT 播放入口使用使用者提供的遠端 TorrServer。播放能力依 MPVKit 所含解碼器與裝置而定；不支援 DRM、需登入 Cookie／自訂 header 的站點解析，也未提供背景播放、畫中畫或 AirPlay。

作品庫位於 App 沙盒 `Application Support/ANI/library.json`，目前為 `version: 3`，包含收藏、分類、已確認來源映射及綁定帳號的待同步修訂，不讀寫桌面版資料。舊 `[Anime]` 格式的 `favorites.json` 先備份為 `favorites.json.backup`；既有 v1／v2 作品庫分別先備份為 `library.json.v1.backup`／`library.json.v2.backup`。升級先寫入並驗證獨立暫存檔，再原子切換，保留來源資料／備份，不雙寫權威資料。舊收藏的身份、文字、數量及順序保留，未知建立時間與分類留空；升級不把舊分類自動送往帳號。

新檔損壞、版本較新或不可讀時顯示「作品庫無法使用」，禁止以空庫或舊檔回退覆寫；資料恢復後按「重試」重新讀取。保存失敗不提前改變收藏／分類，修復儲存問題後可重試載入，再重做原操作。媒體網址只留在當次記憶體，不保存至作品庫或日誌。影片檔案仍透過系統檔案選擇器授權存取。

曾成功載入的基本資訊與完整集數清單獨立保存在 `Application Support/ANI/CatalogCache/`，包含載入時間；進入詳情先顯示快取，再嘗試刷新，離線／刷新失敗保留舊資料並標示時間。快取損壞不會清空收藏或分類，可在線重試重建。封面使用可清除的快取：磁碟最多 64 MiB／256 檔，記憶體編碼圖片最多 12 MiB／64 項；缺圖顯示佔位。系統可能清理圖片快取，從未載入的資訊不保證離線可用；已快取集數不代表影片已下載，來源仍需在線確認。

公用 API 的行動端資料投影與 URLSession client 位於 `iOS/ANI/Catalog.swift`，沿用桌面 Bangumi API 欄位和搜尋契約，避免引用其帳號、快取及 AppKit 依賴。iOS 程式仍遵循根目錄 GPL v3 與原有圖示授權。

## Bangumi 帳號與收藏分類

1. 在收藏頁工具選單開啟「Bangumi 帳號與同步」，前往 [Bangumi 權杖管理](https://bgm.tv/dev/app) 建立個人存取權杖，再貼回安全欄位登入。權杖經 `/v0/me` 驗證後只存本裝置 Keychain；App 不內嵌 OAuth client secret，不把權杖寫入作品庫或日誌。
2. 分類先保存本機，再同步想看、在看、已看、擱置或丟棄。失敗保持待同步，重啟／回前景或按「重試收藏同步」可續送；遠端回應不能覆蓋其間的新修改。觀看秒數、逐集進度、評分及評論不送出；未分類與移除本機收藏都不刪遠端收藏。
3. 未登入時的分類修改保持未指派，登入後須明確選擇「將未指派修改送到此帳號」並確認。已屬於 A 帳號的待同步修改不會送往 B；登出／切換保留本機收藏與待同步資料，可回原帳號重試。
4. 「匯入 Bangumi 收藏」取得全部分頁後，依 Bangumi ID 去重、原子合併；不清除遠端清單外的本機收藏，不覆蓋待同步修改、來源映射或觀看歷史。失敗或取消不提交半份清單。

本功能不是一般跨裝置資料同步；來源映射、連結、觀看秒數和本機檔案不會跟隨 Bangumi 帳號搬移。沒有有效權杖仍可使用公開資訊、收藏及播放。

## 詳情補充資訊與連結收藏

- 詳情的資訊入口分開載入標籤、關聯作品、角色、製作人員與唯讀短評；關聯作品可開啟自己的詳情。各頁有載入、取消、失敗及重試狀態，不阻塞選集播放。
- 短評來自 Bangumi 公開作品評論頁，提供「載入更多」分頁；不提供發送、評分或修改評論。網站改版、權限或網路錯誤會顯示失敗，不當作已載完的空頁。
- 收藏頁工具選單的「連結收藏」獨立保存公開 HTTPS 頁面與標題，支援搜尋、編輯、移除及在瀏覽器開啟。連結不自動建立 Bangumi 作品或播放映射。
- 連結資料位於 `Application Support/ANI/link-favorites.json`（version 1），以正規化頁面及來源身份去重。請貼作品／影片頁，不要貼帶憑證、追蹤或簽名的媒體直連；不能確認為安全頁面身份的網址會拒絕。損壞／未知版本不回退空庫覆寫，寫入失敗保留原清單。資料回歸：`bash Tests/run-ios-links.sh`。

## 實作參考

- [Apple：SwiftUI State](https://developer.apple.com/documentation/swiftui/state)
- [mpv 播放命令與屬性](https://mpv.io/manual/stable/)
- [MPVKit 固定版本與授權](../iOS/THIRD_PARTY.md)

實際驗證結果與未驗證項目見[工作記錄](history/WORK_LOG.md)。

## iPad 工作區

- iPad 使用側欄＋內容區，側欄直接切換探索、Trending、Calendar、收藏與播放，並顯示收藏數量；iPhone 保留底部分頁。
- 主要操作保留至少 44 pt 的點擊範圍，側欄與收藏操作仍為至少 56 pt。作品卡片整張可點，寬版網格的最小卡片寬度為 185 pt。
- 詳情內容區達 700 pt 時封面與資訊並排；播放內容區達 740 pt 時連結輸入和檔案選擇並排。較窄空間與輔助使用大字級改為上下排列，內容可捲動。
- iPad 窄視窗由系統 NavigationSplitView 折疊側欄；不提供桌面版拖曳編排、浮動面板或密集工具列。

離線 UI 案例 `testMobileBrowseAndURLConfiguration` 驗證配置預覽與取消，`testConfigurationOnlyURLImport` 驗證內建來源的搜尋訂閱及完整配置清單匯入，`testDesktopNativeSourcePlayback` 經移植的 Jibi 原生解析器播放隨包影片；BT 選檔／播放器仍由 `testBTEntryPlayback` 驗證。資料回歸入口為 `bash Tests/run-ios-sources.sh`，原生適配器 fixtures 為 `swift test --package-path SourceCore --scratch-path .build/source-core`。實際執行結果與限制見工作記錄。

平板 UI 驗證可指定 `-only-testing:ANIUITests/ANIUITests/testTabletWorkspace`；手機原有流程使用 `-only-testing:ANIUITests/ANIUITests/testMobileFlow`。


## BT 播放入口

從「播放 → BT 播放」輸入可連線且免登入的 HTTPS TorrServer 位址，再貼上 magnet 或 HTTPS `.torrent` URL。按「載入種子檔案」，待伺服器取得中繼資料後選擇影片，由內建 mpv 播放對應檔案。多檔種子保留伺服器檔案 ID，不以列表位置猜測集數。

BT 傳輸由 TorrServer 處理，iPhone／iPad 沒有內建 P2P 引擎。這個入口目前不支援需登入的 TorrServer、HTTP 位址或本機 `.torrent` 檔案；可使用具有效 HTTPS 憑證的反向代理。地址只留在當次頁面記憶體，不保存至觀看歷史。取消會停止手機等待，關閉頁面不會刪除伺服器上的傳輸。

`bash Tests/run-ios-bt.sh` 驗證地址、檔案身份、輪詢、錯誤與取消。UI 測試 `testBTEntryPlayback` 的 `-bt-ui-fixture` 以固定伺服器回應及隨包影片驗證選檔後的真正 mpv 解碼，不代表已驗收遠端 TorrServer 或真實 BT 網路傳輸。

## 內建 mpv 播放器

- **播放／暫停**：影片中央的按鈕；拖動進度條可跳到指定位置。不可跳轉的直播不能使用快進。
- **字幕**：開啟「字幕」選擇內嵌字幕軌，或關閉字幕；可從檔案匯入 SRT、ASS 或 WebVTT。選項以 mpv 實際讀取到的字幕軌為準。內附 Noto Sans CJK TC 字型，讓中文字幕不依賴 libass 對系統字型的搜尋；授權與來源見 [第三方依賴](../iOS/THIRD_PARTY.md)。
- **彈幕**：在「彈幕」匯入該集的 Bilibili XML 或相容 JSON，切換顯示開關、輸入屏蔽關鍵字，或隱藏滾動／頂部／底部類型。這些偏好保存至本機，跨播放及重啟保留；關鍵字可用逗號或換行分隔，忽略大小寫。支援 CDF `stime`（毫秒）、`time`（秒）及 AcFun `c/m` 資料；最多 8 MiB／50,000 條，不執行進階彈幕腳本。匯入失敗保留原資料。自動取得僅限下節的明確來源集數綁定，手動附件優先。
- **彈幕外觀**：開啟「彈幕 → 彈幕外觀」，可選系統或裝置可用字型（含各字型提供的字重款式）、12–48 pt 字級、0.5×–2× 彈幕速度、10%–100% 不透明度，以及來源原色／統一白色；下方提供文字預覽。變更即時套用並跨播放／重啟保存，不改影片倍速、播放位置或暫停狀態。速度同時影響滾動時間及頂／底部停留時間；大字級或較小播放區域會減少同時顯示行數，避免文字互相重疊。字型清單依裝置而異，不提供外部字型檔匯入。
- **速度**：0.5× 至 2×；調整速度不會解除暫停。字幕由 mpv 同步，彈幕依實際媒體時間定位。
- **選集／下一集**：在「檔案」多選影片，或播放中到「選集」加入影片／HTTPS 直連，再選擇要播放的項目。工具列及「選集」提供「下一集」；來源播放會在線重讀原目錄、核對原分組／線路／品質後解析下一集，不從 Bangumi 名稱或集號推測媒體網址。切集清除前集字幕選擇及彈幕，只恢復當次工作階段中屬於目前集數的有效附件與字幕關閉狀態；返回之前的來源集數也重新解析，不重用舊 CDN URL。
- **雙擊快進**：雙擊影片右半邊快進，左半邊倒退；「設定」可選 5／10／15／30／60 秒，也套用到快進／倒退按鈕。此秒數偏好保存在本機；媒體網址和播放清單不跨啟動保存。

影片進入背景、音訊中斷或耳機移除時暫停，回到前景需手動繼續。播放器關閉後，先在背景序列佇列銷毀 libmpv，再釋放 security-scoped 影片／字幕權限。匯入檔案可能包含不受支援的編碼或樣式，應以實際播放結果為準。

### 自動取得點播彈幕

- 「彈幕 → 取得已驗證集數的彈幕」控制自動取得，預設開啟、可關閉並跨重啟保存；顯示開關與取得開關分開。載入中可取消，失敗可重試，不影響影片播放。
- 完整來源 JSON 使用 `version: 2` 才可加入 `danmaku`，其內容為 `{"provider":"bilibili-xml","episodes":[{"pageURL":"該配置允許的精確 HTTPS 播放頁","aid":123,"cid":456}]}`。其中數字僅示意結構，不是可套用的作品綁定；作者須核對來源集數與公開 Bilibili 分 P 確實對應。舊 v1 仍可使用，但不能塞入新彈幕欄位；舊版 App 不會把 v2 誤當 v1 接受。宣告參與配置 fingerprint，更新需重新確認來源映射；搜尋訂閱不能添加或修改這個宣告。
- 僅支援訪客可讀 Bilibili 公開 XML；先核對影片 aid 與唯一分 P cid，再核對 XML chatid。無 Cookie、無登入繞過、不跟隨 redirect，不靠片名／集號搜尋猜配。缺少明確綁定、身份不符或受限內容會顯示不可用；沒有精確綁定的配置不會自動附加彈幕。
- 切集、關閉、取消、來源停用／改版或手動匯入後，舊下載不能附到新集；手動資料優先，關閉自動取得不清除手動附件。公開 XML 彈幕池可能不完整，不代表全部歷史彈幕。
- macOS 保留原生站點／外掛的自動彈幕路徑；這項 JSON 綁定的行動後端不代表桌面通用配置也新增相同後端。

### 同源下一集

- 「選集 → 自動播放下一集」預設關閉，開關跨重啟保存。開啟後僅由當次載入的自然 EOF 接續一次；手動下一集不依賴這個開關。本地檔案使用當次清單順序；手動貼入的媒體連結可能是直播，只支援手動換項，不自動接續。
- 來源下一集保持原來源、作品、目錄分組、線路及品質；缺集、重複身份、配置更改／停用、品質不可用或解析失敗都停止，不換站、不跳過失敗集數。畫面提供原因、重試與取消；重試仍重新核對相同選擇。新集數使用實際來源身份，不自動建立未確認的 Bangumi 集數映射。
- 關閉自動接續、切集、關閉播放器或進入背景會取消待處理接續。背景不啟播，回到前景仍須手動繼續；停止、錯誤、取消與直播不視為自然播完。重播 EOF 集數建立新的載入／歷史 owner，舊完成事件不能覆寫新進度。
- 字幕／彈幕附件按當次清單的集數分開保留，不跨 App 啟動保存；檔案存取權保留到播放器銷毀。選檔期間已切集的結果不套用到新集；無效字幕不取代既有軌道，無效彈幕不清空現有內容。字幕由 mpv 同步，彈幕只跟隨後端實際時間，不使用拖曳預測值。

正式 App 回歸入口：`testSourceNextEpisode`、`testEpisodeAttachmentIsolation`；搭配 `testMPVPlayerControls`／`testMPVPlayerRotation` 驗證實際 libmpv、跳轉及旋轉。固定來源回應與本地影片不代表真實站點或實機通過，結果與限制見[工作記錄](history/WORK_LOG.md)。

### 觀看歷史與續播

啟動或重試讀取歷史時，舊版「· 第03集」這類缺少作品名的記錄，會按既有 Bangumi 作品 ID 從同作品的詳情快取或收藏資料補回名稱；集數、播放位置、完成狀態與觀看時間不變。無法確認作品名時保留原記錄，取得該作品資料後可於下次啟動再修復。

- 探索與播放頁的「繼續觀看」顯示每部作品最近觀看的一集，本地影片獨立列出。點選後重新驗證原來源、配置、集數、線路與品質；媒體載入後，等待 mpv 確認 seek 與實際時間才更新進度。網路或媒體失敗保留舊記錄，來源變更／停用不暗中換站。
- 歷史位於 `Application Support/ANI/playback-history.json`（version 1），獨立於作品庫及快取。只有實際載入並回報有效時間才建立記錄；定期保存，暫停、背景、關閉及切集提交最後有效值。拖曳時間軸的預測數字不算觀看；舊播放器或刪除前的延遲事件不能覆寫／重建記錄。
- 本地影片保存 document-provider 書籤、檔案大小及串流計算的 SHA-256。重新開啟時核對內容；權限失效或原檔找不到時按「重新選擇影片」。移動或改名後內容一致才接受，同名不同內容會拒絕；取消選檔保留歷史。大檔核對期間顯示載入指示，不把整部影片讀入記憶體。
- 手動貼入的 HTTPS 媒體沒有可重解析來源，僅供當次播放，不保存可能帶簽名的 URL。播放清單與字幕／彈幕附件仍不跨啟動保存。
- 本集自然播完標示為「本集已播完」，仍可重新播放；是否接續由「自動播放下一集」決定，不據此推測整季完結。刪除歷史需確認，不刪收藏、來源映射或影片；壞檔／未知版本禁止回退空檔覆寫，儲存錯誤會在播放及歷史入口提示。

回歸入口：`bash Tests/run-ios-history.sh --macos`，或在已啟動模擬器執行 `bash Tests/run-ios-history.sh --simulator <UDID>`。正式 App 的 `testSourceHistoryResume`／`testLocalHistoryResume` 驗證播放到已知秒數、退出重啟、實際 libmpv 續播誤差不超過 2 秒，以及停用來源阻擋。來源 UI 使用固定回應及測試影片，不代表真實站點串流或實機驗收。


本機彈幕資料回歸：`bash Tests/run-ios-danmaku.sh`。播放器 UI 驗證：加上 `-only-testing:ANIUITests/ANIUITests/testMPVPlayerControls`，使用 Debug 專用、可重建的 90 秒測試影片與兩條字幕軌，操作真正的 libmpv。測試素材與啟動入口不納入 Release。

### 橫向與縱向操作

- **縱向**：上方以 16:9 區域播放，進度條與常用功能固定在影片下方；其下顯示目前影片及可捲動的選集清單。較矮視窗會限制影片區高度，讓控制項仍可操作。
- **橫向**：影片使用整個可用畫面，頂部顯示返回與片名，中央是播放／暫停及跳轉，底部集中進度、時間、倍速、字幕、彈幕、選集、設定與全螢幕切換。所有主要按鈕至少 44 pt，倍速使用網格一次顯示全部選項；窄視窗的底欄會改為時間獨立列與兩列功能按鈕。
- 兩種裝置都可以直接旋轉切換佈局。iPhone 的「全螢幕」按鈕會轉至橫向，再按收合按鈕返回縱向；iPad 的按鈕在目前視窗內展開／收合影片，保留系統方向與多工視窗。旋轉裝置後恢復依視窗寬高自動排列。保留同一個播放核心與 Metal surface，不重載影片、不重設時間／選集／字幕。
- 全螢幕播放時閒置 3.5 秒收起控制列；輕點影片可再次顯示，左右半邊仍可雙擊跳轉。暫停、載入、拖動進度、開啟面板或使用 VoiceOver 時保持控制項可見。
- 全螢幕控制列可見時提高一般文字字幕的位置，收起後還原；有自訂定位的 ASS 字幕仍遵循 mpv 的樣式規則。

MPVKit 此版本的 MoltenVK context 不處理一般視窗 resize 通知，因此渲染畫布維持固定 16:9 bounds 與一致的像素尺寸，依螢幕長邊設定，最高 3840×2160。旋轉時只等比例縮放、置中整個 Metal layer，避免暫停畫面、重新繪製的影片與字幕被拉伸或裁切。其他影片比例由 mpv 在畫布內保留比例，可能出現額外黑邊；渲染解析度不隨每次旋轉變動。

互動排列參考 [Video.js 控制列的顯示與隱藏](https://videojs.org/docs/framework/html/guides/controls)，仍由 SwiftUI 與 libmpv 實作。旋轉回歸使用 `-only-testing:ANIUITests/ANIUITests/testMPVPlayerRotation`，檢查感測方向與按鈕往返、狀態保留、自動收起與重新顯示，並擷取兩種格式的實際螢幕畫面。


## 詳情 → 尋源 → 播放

1. 在探索或收藏打開作品詳情，向下查看「選集與片源」。集數按正篇、特別篇、OP／ED 等分組，以自適應網格呈現，按鈕只顯示集數；未到放送日期的集數不能選取。日期未知的集數仍可尋源，放送資料不保證片源已更新。
2. 點選集數，在「片源」清單選擇來源並啟用。內建來源先從「匯入片源配置」下載並套用預填的搜尋訂閱，再按「尋找片源」或「自動尋找可信片源」；未訂閱時仍可手動開啟支援的來源作品頁。搜尋會將作品名稱送至所選第三方網站。停用或切換來源會取消舊請求，不自動啟用新來源。
3. 自動尋源只在完整搜尋結果、作品名稱、年份、類型、明確季度及唯一正篇集數皆可信時播放；缺欄位、同名不同季、未搜尋完、重複集號／多線路或多個候選一律轉回人工確認。手動搜尋仍可選正確作品／季度與線路下的實際集數；畫面保留 Bangumi 集數供比對，不以列表位置或第一個結果推斷。
4. 原生適配器核對作品、線路、集數與可選品質，v1／v2 完整配置使用桌面衍生解析器，v4 使用跨平台靜態頁解析器。Senfun／Dilidili 只在選定集數後取得動態線路，有多個串流時先選擇再播放。付費／試看、驗證頁、未支援加密與不安全媒體按站點規則拒絕；成功後仍交給內建 mpv。
5. 網路暫時失敗提供手動重試；沒有候選、缺集、停用、配置更動、不支援回應與需要登入／驗證則提供對應提示，需改名、啟用或重新確認來源。解析成功且精確身份仍有效後，先保存映射，再交接播放器；保存失敗不啟播，修復儲存問題後可重試。關閉播放器回到已保存來源卡片；要改選來源須先按「重新選擇片源」。取消後抵達的回應不會保存映射或開啟播放器。

來源由 17 個本機內建身份及使用者完整配置組成，按 ID 排序，與桌面共用 `SourceItemRef` 契約。播放解析來自本機適配器或完整配置；訂閱可新增以宣告式規則描述的 v4 靜態來源，不下載執行碼。下一集逐次重新解析及核對原線路／品質。來源啟用偏好按 ID 保存在 iOS UserDefaults，候選、目錄及媒體 URL 留在當次記憶體。訂閱套用成功不代表站點在線、CDN 可存取或裝置能解碼。

M2 已將成功確認的播放上下文保存為精確來源映射：保留 Bangumi 作品／集數 ID、類型、原始排序值，以及來源作品頁、來源集數、線路、可選品質和配置內容 fingerprint。片名與顯示集號不是唯一鍵；保存的頁面只保留配置允許的身份參數，不保存 CDN／簽名網址、帳號或憑證。再次選同一集或重啟後，畫面鎖定原來源，按「播放已保存片源」仍須在線刷新原目錄並重新解析同一集、線路及品質，不沿用舊媒體 URL。來源停用、配置變更、缺集或身份不符會停止，不回退第一集或換站；缺集／配置失效狀態須明確重新選源才清除。單純停用後重新啟用、且配置與身份未改，可重用原映射。移除收藏或清除資訊快取不刪映射；「重新選擇片源」成功移除該集映射後才解鎖選源。M3 的觀看秒數獨立保存，從「繼續觀看」恢復；原始 HTTPS 媒體及 Files 不會被編造成 Bangumi 關聯。

完整配置操作按「配置宣告 ∩ 解析器實作 ∩ iOS 後端」判定，原生來源依實際適配器能力判定；桌面 IINA、下載及其他未移植功能不因來源啟用而出現。完整配置支援 v1／v2 及明確匯入的 v4 靜態頁格式；舊 v3 配置仍不接受匯入或執行。搜尋覆寫與播放修訂分開，更新搜尋不使原播放映射失效。播放器以實際載入與時間事件判定成功，取得媒體 URL 不等於已觀看。

共用契約驗證：`bash Tests/run-multiplatform-contracts.sh --macos`；啟動模擬器後可用 `bash Tests/run-multiplatform-contracts.sh --simulator <UDID>` 執行同份 iOS fixtures。這些檢查不代替正式 App、外站串流或實機驗收。

驗證：`bash Tests/run-ios-sources.sh` 使用 SwiftPM 與固定的 SwiftSoup 2.13.7 在 macOS 跑離線來源回歸，涵蓋保存／重啟重用、配置替換、缺集、停用、過期回應與儲存失敗。模擬器正式 App 的 `testDetailSourcePlayback` 走完整介面，Debug 專用 `-source-ui-fixture` 回傳固定 Bangumi／來源 HTML，仍經正式解析與身份驗證；通過驗證的指定測試 HTTPS 媒體 URL 最後映射至隨包測試影片，使用真正的 libmpv。`-source-ui-failure` 讓第一次解析故意回傳錯誤集數，驗證拒絕且不提供一般重試，明確重選原集後才解析播放；再驗證重啟恢復第二個來源、重新解析播放、停用阻擋與移除映射解鎖。測試入口不編入 Release。這項驗證不代表真實站點端到端播放已通過。

API 與解析參考：[Bangumi API](https://bangumi.github.io/api/)、[SwiftSoup selector 文件](https://github.com/scinfu/SwiftSoup/wiki/Use-selector-syntax-to-find-elements)。

### CSS1 搜尋訂閱與原生來源

- 訂閱網址預填 `https://sub.creamycake.org/v1/css1.json`，可改為自己的公開 HTTPS 配置網址；匿名下載最多 2 MiB、最多 5 次 HTTPS 重新導向，不攜帶登入資訊。
- 17 個支援身份為 `xifan`、`girigiri`、`didahd`、`jibi`、`eacg`、`senfun`、`fengche`、`kanba`、`haixing`、`yinghua`、`dilidili`、`youknow`、`fqdm`、`hanime1`、`wedm`、`mutedm`、`rebo`。其中 fqdm 使用內建完整配置，其餘使用從桌面移植的原生適配器；不包含 Bilibili 或直播平台。
- 根層級 `mediaSources` 優先於舊格式 `exportedMediaSourceDataList.mediaSources`。搜尋支援 `a`、DOM 結構配對的 `indexed`，以及共同陣列下的受限 JSONPath；關鍵詞可以出現在路徑或查詢中，支援頁碼模板。
- 依已安裝來源的精確主機辨識身份；未知站可按配置轉為獨立 v4 靜態來源，不以遠端名稱冒用原生適配器。無效規則與衝突項目保留舊設定，缺項不刪除。既有來源變更搜尋規則仍先驗證；新靜態來源只驗證配置結構，網站可用性需實際搜尋與播放確認。
- 預覽顯示逐項差異及保留原因。確認才原子保存，取消、失敗或過期預覽不更動原資料；套用不啟用來源，也不改變已保存的播放選擇。
- 原生播放保留桌面站點專用行為：例如 XiFan 新舊路由及精確來源參數、mutedm 的網頁／App 專線限制、Didahd 的受限 HLS loopback 處理，以及 Hanime1 的明確品質選擇。不能以單一通用 MacCMS 規則代替所有站點。
- 新增跨平台 v4 靜態來源：支援 index-grouped／no-channel 集數規則、HTML5 與 MacCMS encrypt 0／1／2 直連，保留精確作品及播放頁身份。需要遠端腳本、特殊解密或網站驗證時顯示限制，不暗換來源。舊 v3 資料仍保留並停用，不自動升級；原生 ID／網域不可被冒用。



### 由 URL 匯入來源

- 匯入欄位預填 CSS1 訂閱，也可貼上自己的 HTTPS Animeko 訂閱、完整配置或清單網址。主動下載後才請求資料，預覽不保存；確認後新增靜態來源與搜尋更新原子寫入，來源需手動啟用。一般網頁不能當作配置文件。
- 原生格式支援單個完整配置物件、完整配置物件陣列，以及 `{"version":1,"sources":[...]}` 清單。清單項目可以是完整配置物件或指向完整配置 JSON 的 URL 字串；相對 URL 以清單下載完成後的最終位置解析，絕對 URL 必須使用 HTTPS。清單中的 `version: 1` 是清單格式，個別來源仍保留自己的配置版號。
- 每份下載回應最多 2 MiB，個別完整來源配置最多 1 MiB，一次清單最多 100 個來源，下載累計最多 16 MiB；超限不提交。URL 與重新導向都需維持 HTTPS，不接受內嵌帳號密碼，請求不沿用帳號 Cookie 或授權 header。
- 下載後先查看名稱、ID 與網域再確認匯入；單份完整配置另顯示有效／不可用能力及內容 fingerprint；同 ID 來源會標示為替換。清單會驗證全部項目，拒絕重複 ID 與無效來源，避免只加入前半份清單。只有確認後才保存，取消或下載／驗證失敗保留原配置。匯入的完整來源需要手動啟用；內容變更會使既有映射要求重新確認。
- 完整配置包含 `id`、`name`、`version`（1 或 2）、`hosts`、`capabilities`、`route`、`catalog`、`player`，以及可選 `search`；v2 另可宣告 `danmaku`。僅有搜尋 CSS 規則的 `native-search.json` 或桌面來源訂閱不能當作完整來源匯入。帳號 Cookie、token、任意 headers 與遠端程式碼不屬於此格式。
- 匯入資料保存在 App 沙盒 `Application Support/ANI/Sources/`。批次狀態 `ConfigurationImports/state.json` 以原子方式提交；舊 `<id>.json` 與 `SearchSubscription/state.json` 保留。錯誤、衝突或不相容項目提供提示，不刪除原檔。內建身份不被不相容舊配置遮蔽，既有映射仍需通過修訂與身份核對；新匯入配置不能取代原生內建 ID／網域。
- [Internet Archive 完整配置範例](../Examples/MobileSources/internet-archive.json) 展示 JSON 搜尋、JSON 目錄與媒體網址模板；[來源清單範例](../Examples/MobileSources/source-list.json) 以相對路徑引用它。將兩份檔案放在同一個可由 HTTPS 存取的目錄後，即可用清單 URL 匯入；此範例不會隨 App 自動安裝。它是一般公開影片來源，並非番劇匹配保證；實際影片／檔案需要自行確認。
- 不含 `search` 的來源仍可啟用，透過「開啟片源作品頁」輸入配置允許的 HTTPS 作品頁，載入目錄後選集播放。

`catalog` 可以使用 HTML selector，或 JSON 的 `jsonTitlePath`、`jsonEntriesPath`、`jsonEpisodeTitlePath`、集數身份／網址與可選線路／集數欄位；欄位路徑支援點分隔與陣列索引。`player` 可選 HTML regex payload、JSON payload 路徑，或 `streamURLTemplate`；模板支援 `{id}`、`{line}`、`{episode}`、`{file}` 並做 URL 編碼。所有結果仍需通過 host、作品／集數身份、付費／試看與媒體副檔名驗證。選集按鈕不顯示名稱或放送日期，完整名稱保留給輔助使用讀取。
