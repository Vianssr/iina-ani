# SourceCore

macOS `IINA-ANI` 與 iOS `ANI` 共用的本機 Swift Package，支援 macOS 13+／iOS 17+。提供 `SourceCore` 與 `SourceRuntime` 兩個產品，兩端 Xcode target 都連結它們。

授權沿用儲存庫根目錄的 [GPL v3](../LICENSE)。

- `SourceSelection`：來源頁身份、精確選集、播放上下文、映射與共用錯誤。
- `SourceCapabilities`：來源能力、平台能力交集與搜尋結果。
- `SourceConfiguration`：完整配置 schema、內容修訂、URL／媒體驗證及映射正規化。
- `SourceSubscriptionRules`：經核對的訂閱主機與 indexed selectors。
- `PublicPlayerProtocol`：固定公開播放器協議與解密；HTTP 請求由呼叫端注入。兩端傳輸共用 `requestTimeout(for:)`：指定動態解析 API 的 POST 最多等 45 秒，靜態頁面、腳本及 CDN 探測維持 20 秒。

`SourceCore` 使用 Swift 6，只依賴 Apple 的 Foundation、CryptoKit 與 CommonCrypto。`SourceRuntime` 使用 Swift 5 語言模式，依賴 SourceCore、SwiftSoup 2.13.7 與 CryptoSwift 1.9.0；包含從桌面移植的 16 個 CSS1 來源原生解析器、完整配置解析器、HTTPS 傳輸，以及兩端共用的搜尋訂閱轉換／下載政策。播放器引擎、帳號 UI 與使用者儲存仍由 App 管理。桌面既有原生站點適配器及帳號傳輸不因行動端移植而替換。

原有完整配置的必填欄位與持久化身份保持相容；新增搜尋欄位為可選，未使用時不改配置修訂。原生適配器使用獨立且穩定的 SHA-256 播放修訂。切換行動端來源後保留舊資料，v3 `webSelector` 仍停用；新匯入的靜態來源使用明確的 v4。套件沒有 `MOBILE_SOURCES` 編譯分支。

## 行動端來源執行層

- 內建 17 個經審核的來源身份：16 個原生適配器加上完整配置 `fqdm`。來源預設不啟用；CSS1 只更新支援的公開搜尋規則，不建立遠端播放解析器。搜尋基線與 fqdm 資源來自桌面。
- 訂閱可從使用者輸入的公開 HTTPS 網址下載，預設仍為 creamycake CSS1；匿名請求、最多 5 次重新導向及 2 MiB 回應。同時支援根層級 `mediaSources` 與舊巢狀格式，根層級優先。既有來源按精確主機匹配，搜尋支援 `a`、DOM 配對的 `indexed` 與共同陣列下的受限 JSONPath；不以名稱推斷身份。
- 未知來源可轉為明確的 v4 靜態頁配置，由共用 `StaticWebSourceClient` 搜尋、取得目錄及解析 HTML5／MacCMS 0、1、2 直連；原生身份／主機不被新來源覆寫。新來源須預覽套用並啟用，遠端 Cookie、header、任意 JavaScript 及影片嗅探規則不執行。需要特殊協議、驗證或失效媒體時保留具體錯誤；轉換成功不是可播證明。
- `RuntimeSource` 區分真實完整配置與原生適配器，不以假的配置模擬原生解析。搜尋覆寫修訂與播放身份修訂分開；選集、線路及品質必須精確匹配。
- Senfun／Dilidili 的動態線路只在使用者選定集數後取得；多個可用串流須明確選擇，不在載入目錄時解析整季影片。
- Didahd 的特殊 HLS 使用受限 loopback 服務處理已驗證的播放清單及片段；不啟用任意 URL 代理。iOS 仍由嵌入式 libmpv 播放。
- 舊行動 v3 `webSelector` 配置僅保留資料，不再執行。不得按名稱／網域猜測遷移來源與映射；不相容選擇需要重新確認。


驗證：

```sh
swift test --package-path SourceCore --scratch-path .build/source-core
bash Tests/run-multiplatform-contracts.sh
bash Tests/run-ios-sources.sh
```

`Tests/Support/source-core.sh` 讓獨立回歸程式連結共用模組；模擬器契約測試會以相同 Swift 6 原始碼編譯模組。App 整合仍須分別建置根目錄及 `iOS/` 的 Xcode 工程。
