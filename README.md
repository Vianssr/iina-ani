# IINA-ANI

[xjbeta/iina-plus](https://github.com/xjbeta/iina-plus) 的非官方重構 fork。以原有站點解析、IINA／mpv、彈幕及內建 JSPlayer 為基礎，提供追番搜尋、Bangumi 資訊、收藏、下載及可自訂的 Workspace／Layout／Skin。

**目前是開發基線，不是獨立發佈版本。** 原始碼倉庫為 [Vianssr/iina-ani](https://github.com/Vianssr/iina-ani)。Bundle ID 及既有資料目錄仍沿用上游；不要與上游混用資料。尚未配置更新服務、正式簽署及公證。保留上游 GPL v3、作者與圖示授權，不代表與 IINA、IINA+ 或 Animeko 有官方關係。

## 專案導覽

| 路徑 | 職責 |
| --- | --- |
| `IINA-ANI/App/` | AppDelegate、AppServices 組裝根、偏好與原生選單 |
| `IINA-ANI/Features/` | Accounts、Bangumi、Discovery、Sources、Playback、Downloads、Torrent |
| `IINA-ANI/Infrastructure/` | Persistence、HTTP、本機圖片 Cache |
| `IINA-ANI/Workspace/` | Shell、Panels、Settings、Layout、Skin |
| `IINA-ANI/Shared/` | 共用 extensions、日誌及小型工具 |
| `IINA-ANI/Assets/`、`WebFiles/`、`Sources/`、`Core Data/` | 圖像、網頁播放器、來源配置與版本化 Core Data schema；後三者同樣位於 `IINA-ANI/` |
| `IINA-ANI.xcodeproj/` | 唯一 App 工程；scheme／target：`IINA-ANI` |
| `Config/` | 共用建置設定、空白 OAuth 範本；本機憑證檔不進 Git |
| `HuyaKit/` | 虎牙協議與 `huyaproxy` Swift package |
| `Native/` | Torrent C ABI／原生核心及受限 LayoutScript helper |
| `Tests/` | 按功能分類的回歸程式、fixtures；`run-*.sh` 保留於根層 |
| `Examples/`、`Design/` | Skin／頁面動效範例及圖示來源 |
| `docs/` | 使用指南、架構約束、規劃、研究與歷史驗證 |
| `.github/ISSUE_TEMPLATE.md` | 問題回報模板 |

目錄分層不建立新的 Swift module；現有服務 ownership、持久身份、資源名稱及外掛協議維持不變。功能服務不依賴 Workspace UI；AppServices 負責組裝，Workspace 負責呈現與使用者操作。詳細邊界見 [專案架構](docs/architecture/PROJECT.md)。

## 建置

需要 macOS、完整 Xcode、Swift tools 6.4、Node.js／npm 與 GitHub CLI `gh`。App 宣告最低 macOS 13.5，不代表已實測最低系統。以下指令於 checkout 根目錄執行：

```sh
# 下載外部彈幕外掛及 npm 資源；可傳入真實 release tag 固定外掛版本
bash InstallDeps.sh

xcodebuild -resolvePackageDependencies -project IINA-ANI.xcodeproj
xcodebuild -project IINA-ANI.xcodeproj -scheme IINA-ANI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

首次建置會下載 `Native/deps.lock` 固定的原生依賴並檢查 SHA-256。`.build/`、npm dependencies 及下載的 `.iinaplgz` 不進 Git；新 checkout 必須先安裝依賴，不能刪除 Xcode 資源引用來繞過缺檔。`CI=true` 的依賴安裝會改寫內建外掛版本常數，提交前須檢查該來源變動。

完整依賴、播放器與 FFmpeg 要求見 [使用指南：建置](docs/USER_GUIDE.md#建置)。

### Bangumi 登入配置

公開原始碼不含 OAuth 應用憑證。需要 Bangumi 帳號登入時：

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

在本機檔填入自己應用的 `BANGUMI_CLIENT_ID`／`BANGUMI_CLIENT_SECRET`，並於 Bangumi 註冊回調 `iina-ani://bangumi/oauth`，再重新建置。`Config/App.xcconfig` 由 Debug／Release 共用並選擇性載入本機檔；未配置仍可建置，登入／續期會明確拒絕，不發送空憑證請求。不要把個人 access token 填成 client secret。

`Config/Local.xcconfig` 已忽略。**這只避免憑證進 Git，不會讓桌面 App 內的 secret 保密**：建置後值存在 App bundle，可被取出；公開分發前須評估 Bangumi 應用註冊及授權架構。原憑證曾明文存在於本機來源，建議擁有者在開發者平台輪替，勿上傳舊來源備份或含建置設定的日誌。

## 驗證入口

先建置 App，再按改動選擇現有入口；各腳本仍可從根目錄直接執行：

```sh
bash Tests/run-dependency-regression.sh --unit
bash Tests/run-w7-usecases.sh
bash Tests/run-workspace-layout.sh
bash Tests/run-workspace-renderer.sh
bash Tests/run-skin-appearance.sh
bash Tests/run-skin-package-store.sh
node Tests/Playback/JSPlayerAutoplayRegression.js
```

離線回歸不等於真實播放或正式 App 驗收。HTTP integration、Torrent、播放器及完整功能說明見 [使用指南](docs/USER_GUIDE.md)；實際驗證證據與限制見 [工作記錄](docs/history/WORK_LOG.md)。既有最低系統／Intel、正式簽署與產品集中驗收的未簽收項仍保留。

## 原始碼倉庫

原始碼發布於 [Vianssr/iina-ani](https://github.com/Vianssr/iina-ani)，預設分支為 `main`。新環境可直接取得：

```sh
git clone https://github.com/Vianssr/iina-ani.git
cd iina-ani
```

倉庫保留共用建置設定與空白 OAuth 範本；本機憑證、助理指令／設定、個人 IDE 狀態與建置產物不隨原始碼發布。

提交前核對：

- 保留 App／HuyaKit 的 `Package.resolved`、`package-lock.json`、`Native/deps.lock`、原始碼、fixtures、必要資源及共用 Xcode scheme。
- 排除 `.build`、DerivedData、`node_modules`、下載外掛、`xcuserdata`、本機助理狀態、環境憑證與簽署私鑰；不要用 `git add -f` 繞過。
- 不上傳 Cookies、token、授權 header、帶簽名的串流 URL、使用者 Application Support／偏好／播放歷史。忽略規則不是憑證掃描器，仍須檢閱暫存內容。
- 原始碼上傳不等於可公開散發 App；獨立產品身分、資料遷移、第三方授權及正式簽署要求見 [發佈邊界](docs/architecture/PROJECT.md#6-fork-身分安全與發佈邊界)。

## 文件與授權

- [功能與操作指南](docs/USER_GUIDE.md)
- [專案定位、架構及發佈安全](docs/architecture/PROJECT.md)
- [前端重構計劃與驗收狀態](docs/plans/FRONTEND_REFACTOR_PLAN.md)、[W0 歷史基線](docs/plans/FRONTEND_W0_BASELINE.md)
- [Torrent 研究](docs/research/ANIMEKO_TORRENT_REVIEW.md)、[來源接入研究](docs/research/websitesforanime.md)
- [Skin 作者格式](Examples/Skins/README.md)、[逐次工作記錄](docs/history/WORK_LOG.md)
- [GPL v3](LICENSE)、[圖示授權](LicenseForIcons.pdf)、`Native/licenses/`
