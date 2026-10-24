# 建置與驗證

- Swift tools 需滿足 HuyaKit 的 6.4；App target 宣告 macOS 13.5，不能據此宣稱已實測最低版本。
- 依賴安裝入口是 `bash InstallDeps.sh`。該腳本會下載外部外掛並執行 npm；`CI=true` 還會改寫內建外掛版本常數，執行前留意其副作用。
- App 建置使用[使用指南](../USER_GUIDE.md#建置)的 `xcodebuild` 指令；產物放在 `.build/xcode` 或專案外的 DerivedData。
- `swift package --package-path HuyaKit dump-package` 只驗證 manifest，不代表 library／CLI／App 已建置。
- 驗收必須建置並啟動這份來源的 `IINA-ANI.app`，走正式 AppDelegate、操作實際視窗並截圖；不得以隔離 host 或舊產物代替。播放與彈幕須驗證載入、取消、重連、多視窗及釋放；成功呼叫 URL scheme 不等於播放通過。
- 報告分開列出原始碼檢查、manifest／工程檢查、建置與執行驗證；未執行的步驟明確標示。
- 功能變更依影響範圍執行 `Tests/run-*.sh` 與正式 App 驗收；純文件變更只檢查文件，不宣稱執行 App 驗收。驗證入口與各自限制見[使用指南](../USER_GUIDE.md#驗證與回報)。
