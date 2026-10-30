# iOS 播放核心依賴

iPhone／iPad 工程透過 Swift Package Manager 連結 [MPVKit](https://github.com/mpvkit/MPVKit) 的 `MPVKit` 產品，鎖定 `1.1.0-n9.0.2` 標籤對應的 commit `98c3453e252922e3136422da3fbb2e341ed9edc8`。實際鎖檔在 `ANI.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`；上游 manifest 為各個二進位 XCFramework 宣告 SHA-256 校驗值。

- [固定版本的 Package.swift](https://github.com/mpvkit/MPVKit/blob/98c3453e252922e3136422da3fbb2e341ed9edc8/Package.swift) 列出 libmpv、FFmpeg、libass、字型與編碼函式庫、libplacebo、MoltenVK 及 TLS 相依項。這些是靜態庫，支援 iOS arm64 與 iOS Simulator arm64／x86_64；原生二進位由 SwiftPM 下載，不納入本專案原始碼。
- [上游建置腳本與 patch](https://github.com/mpvkit/MPVKit/tree/98c3453e252922e3136422da3fbb2e341ed9edc8/Sources/BuildScripts) 是對應重建入口。`MPVEngine.swift` 使用 libmpv C client API，透過上游 MoltenVK context patch 將影片繪入 `CAMetalLayer`。此 Metal 路徑是 MPVKit 提供的 patch，不能視作 mpv 官方對 iOS 的完整支援承諾。
- MPVKit 授權原文保存在 [MPVKit-LGPL-3.0.txt](../Native/licenses/MPVKit-LGPL-3.0.txt)，並隨 App 資源打包。各相依項仍各自保留其授權；產品未選用含 Samba 的 `MPVKit-GPL` 變體。本專案自身沿用根目錄 [GPL v3](../LICENSE)。
- HTTPS 驗證保持啟用；App 打包現有的 [Mozilla CA bundle](../Native/licenses/cacert.pem) 並設為 `tls-ca-file`，同時保留 [MPL-2.0](../Native/licenses/MPL-2.0.txt)。更新信任根時須同步核對 CA bundle 的來源與日期。
- 字幕隨 App 打包 [Noto Sans CJK TC Regular 2.004](https://github.com/notofonts/noto-cjk/releases/tag/Sans2.004)，取自官方 `notofonts/noto-cjk` commit `523d033d6cb47f4a80c58a35753646f5c3608a78` 的未修改單一 OTF（16,435,884 bytes），補足 libass 在 iOS 上的中日韓文字形。字型及其 [SIL Open Font License 1.1](ANI/Fonts/OFL.txt)、[版權／來源／SHA-256 記錄](ANI/Fonts/NOTICE.md) 一併複製到 `ANI.app/Fonts/`；由 `sub-fonts-dir` 載入，預設字幕字型為 `Noto Sans CJK TC`，不替換 App 的系統介面字型。

本次為本地開發整合；正式分發前仍需準備完整相依項版權聲明、對應原始碼／重建與重新連結所需材料，並完成簽署及實機測試。本檔及 MPVKit 的單一授權副本不代表全部分發工作已完成。

## 核心邊界

播放器關閉時先由同一序列佇列取消輪詢並銷毀 libmpv，再釋放 Metal layer 與檔案授權；`stop(onStopped:)` 的 callback 在銷毀之後呼叫。載入、跳轉、速度及字幕均操作實際 libmpv 屬性／命令；不使用 AVPlayer 代替播放。App 不將 libmpv 原始日誌、完整媒體 URL 或字幕 URL 寫入 console／觀看歷史。

暫不提供背景播放、畫中畫、AirPlay 或 DRM。來源解析由完整宣告式配置驅動，內建番茄動漫並可匯入其他相容來源。進入背景、音訊中斷及耳機移除會暫停；回到前景由使用者繼續播放。


## HTML 來源解析

iOS 工程新增固定版本 [SwiftSoup 2.13.7](https://github.com/scinfu/SwiftSoup/tree/2.13.7)，與桌面目前鎖定版本一致。用於解析搜尋結果、線路與集數 HTML，不執行頁面 JavaScript。MIT 授權原文位於 [SwiftSoup-MIT.txt](../Native/licenses/SwiftSoup-MIT.txt)，隨 App 資源打包。
