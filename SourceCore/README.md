# SourceCore

macOS `IINA-ANI` 與 iOS `ANI` 共用的本機 Swift Package，使用 Swift 6，支援 macOS 13+／iOS 17+。兩個 Xcode target 都連結同一個 `SourceCore` product，呼叫端使用 `import SourceCore`。

授權沿用儲存庫根目錄的 [GPL v3](../LICENSE)。

- `SourceSelection`：來源頁身份、精確選集、播放上下文、映射與共用錯誤。
- `SourceCapabilities`：來源能力、平台能力交集與搜尋結果。
- `SourceConfiguration`：完整配置 schema、內容修訂、URL／媒體驗證及映射正規化。
- `SourceSubscriptionRules`：經核對的訂閱主機與 indexed selectors。
- `PublicPlayerProtocol`：固定公開播放器協議與解密；HTTP 請求由呼叫端注入。兩端傳輸共用 `requestTimeout(for:)`：指定動態解析 API 的 POST 最多等 45 秒，靜態頁面、腳本及 CDN 探測維持 20 秒。

套件只依賴 Apple 的 Foundation、CryptoKit 與 CommonCrypto，不依賴 App target、播放器引擎、儲存或站點帳號。平台的解析器、CSS1 轉換、網路傳輸與功能支援範圍仍由各 App 管理。桌面的 `PublicPlayerProtocol` extension 保留既有傳輸；`ConfiguredSource` 在邊界將 `.invalidMedia` 轉為原有的 `VideoGetError.notFountData`。

JSON 欄位、配置修訂算法與持久化身份保持不變；本次抽取不需要遷移使用者資料。套件沒有 `MOBILE_SOURCES` 編譯分支。

驗證：

```sh
swift test --package-path SourceCore --scratch-path .build/source-core
bash Tests/run-multiplatform-contracts.sh
bash Tests/run-ios-sources.sh
```

`Tests/Support/source-core.sh` 讓獨立回歸程式連結共用模組；模擬器契約測試會以相同 Swift 6 原始碼編譯模組。App 整合仍須分別建置根目錄及 `iOS/` 的 Xcode 工程。
