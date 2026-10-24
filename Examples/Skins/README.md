# Skin v1 作者範例與公開槽契約

本目錄對應目前 `SkinModel`／`SkinPackageValidator`／`SkinArchive`／`SkinStore`，不是計畫中的未開放格式。`minimal/` 是無 components、無自訂素材的局部 token 覆蓋，附淡入（fade）頁面動效；`full/` 包含 19 個公開槽 × 8 狀態、七組件 header 覆蓋、26 個原創 PNG 素材（兩個明暗背景及三角色各八狀態），附滑入（slide）頁面動效。兩者都有明暗變體、原創展示圖及作者 Layout。展示圖只是幾何作者圖，不是假造 App screenshot，也不取代原生預覽。

使用者操作及各項功能解說見 [Skin 功能指南](../../docs/SKIN_GUIDE.md)；本文集中維護作者檔案格式、組件契約與打包限制。

## 產生、打包及匯入

在 repository 根目錄執行：

```sh
# 可選：重建範例 JSON、motions/page.xml 與所有原創幾何 PNG；會覆寫作者目錄內的範例文件。
python3 Examples/Skins/generate.py
# macOS + Xcode command-line tools；輸出目錄中不得已有同名包。
bash Examples/Skins/package.sh /tmp/my-skin-packages
```

第二步使用生產 Swift validator 與 ZIP 實作，輸出 `minimal.iinaskin`、`full.iinaskin`，不是以一般 zip 遞迴打包 repository。工具只驗證與打包，不啟動正式 App、遠端服務或播放器，也不修改已安裝 Skin／使用者 profile。

將生成包由工作區外觀入口選檔、拖入或開包，直接進入真實原生預覽；版本、作者與授權 metadata 在可信預覽頂部呈現，長文字可透過提示及無障礙名稱完整讀取。預設只套外觀，「外觀＋作者 Layout（取代目前排列）」預設不勾選；勾選時同一預覽視窗即呈現作者佈局，按套用才提交。管理頁提供清單、版本／作者／授權、移除、匯出及恢復。作者編輯可直接載入 `minimal/` 或 `full/` 目錄；保存 JSON／素材後明確使用「重新載入並預覽」，不是自動監視／自動提交。重載以隔離 snapshot 通過相同 validator，錯誤定位到檔案／欄位；取消或失敗不取代已套外觀，預覽不執行播放／下載業務命令。不要選本目錄根層（README、工具不是包內容），不要把 `.DS_Store`、授權文字文件或打包腳本塞進作者目錄。

## 包結構與 manifest

UTF-8 JSON；ZIP Stored 或 Deflate；副檔名 `.iinaskin`。包根直接有 `manifest.json` 和 theme 入口，不能多包一層作者目錄。只有 manifest、theme／components／pageMotion 入口、`preview.png` 及 `assets` 明列的檔案允許入包。

| manifest 欄位 | 精確格式 |
| --- | --- |
| `schemaVersion`, `componentContractVersion` | 整數，均為 `1` |
| `minimumAppVersion` | 1–3 段非負整數版本字串，不高於目前 `0.8.32` |
| `id`, `version`, `name`, `license` | 非空字串；穩定 id 區分作者包。**欄位是 `version`，不是 `packageVersion`** |
| `revision` | 非負整數 |
| `author` | 可選字串；未驗證作者身份 |
| `supportedVariants` | 非空陣列，只能 `light`／`dark`，不能 `system` |
| `entryPaths` | 物件，只接受 `theme`、`components`、`pageMotion` 相對路徑。theme 預設 `theme.json` 且必需；components 未列時可有可無，預設 `components.json`，明列則文件必需。pageMotion 沒有預設入口，僅明列時載入且文件必需 |
| `assets` | 素材 ID → 相對包根路徑；每 ID 只對應一個檔案，不可與入口／preview 重名 |
| `assetAttributions` | 素材 ID → 授權／作者文字；key 必須已存在 assets；以 `font` 開頭的素材 ID 必需非空歸屬 |
| `provenance` | 字串物件；只接受 `originalID`, `originalName`, `originalAuthor`, `originalLicense`, `sourceDigest`, `derivedFrom`, `derivedAt` |
| `layout` | 可選內嵌 WorkspaceLayout v1；**不接受 `layouts/` 入口或 JavaScript** |

範例完整寫出集合／物件欄位以符合 Codable 解碼；未知欄位、未知槽／狀態／token 會被拒絕，不是靜默忽略。路徑不可絕對、含 `:`／反斜線、空段、`.` 或 `..`；不讀遠端 URL。檔案路徑不得大小寫或 Unicode 正規化碰撞。

## Skin 頁面動效

在 manifest 明列 `"entryPaths": { "theme": "theme.json", "pageMotion": "motions/page.xml" }`，即可將動效與外觀一併預覽、安裝及分享；不必附 Layout。XML 直接採用 [`../PageMotions/`](../PageMotions) 的 `WorkspacePageMotion` v1 格式：minimal 取 `fade.xml`、full 取 `slide.xml`，generator 每次都重建各包的 `motions/page.xml`。

```xml
<?xml version="1.0" encoding="UTF-8"?>
<pageMotion version="1" duration="0.25" opacity="0"
            offsetX="0" offsetY="16" scale="1" curve="easeOut"/>
```

只接受一個 `pageMotion` 根元素與上述七個屬性；`version` 必須為 `1`。`duration` 為秒數 `0…5`、`opacity` 為 `0…1`、`offsetX`／`offsetY` 為點數 `−2048…2048`、`scale` 為 `0.1…4`；數字必須有限。`curve` 只接受 `linear`／`easeIn`／`easeOut`／`easeInOut`。檔案須為 UTF-8、最多 16 KiB；未知屬性、子節點、DTD／entity、腳本與遠端資源均不接受。入口沿用包內安全相對路徑規則；明列但缺檔、格式錯誤或超限會拒絕整包，不會靜默降級。

Skin XML 是**預設動效**：頁面 `page.motion == .none` 時使用 Skin 的動效；頁面已有非 none 自訂動效時，頁面設定優先。以 [`none.xml`](../PageMotions/none.xml) 作為入口會關閉 Skin 預設動效，但不覆蓋頁面自訂動效。未列 `entryPaths.pageMotion` 的舊包完全不變，不會自動尋找或載入 XML；未列入入口的 XML 檔案也不能入包。

**純 Skin 套用不修改、保存或取代 Layout**，動效在顯示時解析；只有明確勾選「外觀＋作者 Layout」才提交作者佈局。原包匯出與衍生分享均保留 XML，即使分享選擇「不帶 Layout」，Skin 預設動效仍隨包保留；分享目前／作者 Layout 時，頁面自訂 `motion` 也保留。恢復內建外觀只移除 Skin 預設，不清除 Layout 中的自訂動效。App 的減少動態效果設定仍優先，不因 XML 啟用而繞過。

## theme、components 與 cascade

`theme.json` 為 `{ "system": {}, "light": {}, "dark": {} }`。`system` 是兩變體共用 token，不是第三個 supportedVariant；light／dark 覆蓋共用值。未支援變體不自動反色。token 可只定義一部分，其他沿用內建。

| token | 型別與 validator limits |
| --- | --- |
| `foreground`, `background`, `borderColor` | 6／8 位 hex 字串，可帶 `#` |
| `fontFamily` | 非空字型名稱字串；省略使用 macOS 系統字體。範例不隨附或再散布系統字體 |
| `fontSize`, `spacing`, `radius`, `borderWidth` | 有限數字 `0…2048`（合法上限不是建議可用設計尺寸） |
| `opacity` | 有限數字 `0…1` |
| `density` | `compact`／`regular`／`comfortable` |
| `backgroundAsset`, `iconAsset`, `placeholderAsset`, `decorationAsset` | 字串，引用 `manifest.assets` 中 ID，**不是直接檔案路徑** |

components 為 `{ "slots": { "槽名": { "values": {}, "states": { "normal": {} } } }, "overrides": { "componentID": { "槽名": { "values": {}, "states": {} } } } }`。每個 style 必須有 `values` 和 `states` 物件。共用槽與按穩定 componentID 的覆蓋用相同 token。解析次序：內建 → 共用／明暗 theme → 槽 values／normal／目前狀態 → 組件覆蓋 → 此 Skin 個人覆寫；不使用 Swift 類名或動態原生類載入。

公開語義槽：`workCard`, `list`, `search`, `navigation`, `primaryAction`, `tabs`, `progress`, `background`, `icon`, `placeholder`, `decoration`。

| 穩定 componentID | registry 公開槽 | 最小 width × height |
| --- | --- | --- |
| `discovery.schedule` | panel, header, row, emptyState | 480 × 180 |
| `discovery.updates` | panel, header, row, emptyState | 480 × 180 |
| `discovery.recommendations` | panel, header, row, emptyState | 480 × 180 |
| `playback.continue` | panel, header, row, progress, emptyState | 480 × 72 |
| `discovery.feed` | panel, header, row, primaryAction, emptyState | 480 × 240 |
| `discovery.followed` | panel, header, row, primaryAction, emptyState | 480 × 240 |
| `discovery.bilibiliRecommendations` | panel, header, row, primaryAction, emptyState | 480 × 240 |
| `discovery.youtube` | panel, header, row, search, primaryAction, emptyState | 480 × 320 |
| `search.results` | panel, header, result, emptyState | 480 × 320 |
| `downloads.tasks` | panel, header, task, emptyState | 480 × 320 |
| `favorites.works` | panel, header, workRow, emptyState | 280 × 200 |
| `favorites.links` | panel, header, linkRow, emptyState | 280 × 200 |
| `detail.media` | panel, header, list, row, primaryAction, emptyState | 560 × 420 |
| `settings.preferences` | panel, header, list, search, primaryAction, emptyState | 600 × 420 |
| `torrent.import` | panel, header, list, row, progress, primaryAction, emptyState | 560 × 420 |

全部狀態：`normal`, `hover`, `pressed`, `selected`, `focus`, `disabled`, `loading`, `error`。若某非 normal 狀態指定某圖片角色，該 style 的 values 或 normal 必須先指定同角色 fallback。未指定狀態仍保留原生焦點／停用效果，不從其他 Skin 拼圖。full 的透明圖示／占位／裝飾可共用於明暗背景；每狀態提供不同色階圖及選取／焦點邊框、停用 opacity。每控件只呈現適用狀態，列出槽／狀態不表示會將所有狀態強制展示。業務文案、可存取名稱、點擊範圍、可信安全提示和固定恢復入口始終由 App 控制。

`detail.media`（R4）內部固定為身份／海報或縮圖 → 簡介與資訊 → 集數／分 P → 播放／來源／品質／收藏／下載；分類與關聯／映射在預設收合的「更多」。Skin 可改字體、色彩、密度與公開槽外觀，Layout 可放置整個組件，但不能重排其語義區塊、增加直播季集或繞過命令資格。缺資料的未知／空狀態由 App 決定；內建詳情 header 預設 24 pt，作者／個人 fontSize 覆寫仍生效。

## Layout v1

`layout` 包含 `schemaVersion: 1`、`pages`、可選 `breakpointLayouts`。page 是 `{id: UUID, title: string, root: node, motion?: object}`；node `id` 是 UUID，component 使用字串 `componentID`、整數 `contractVersion: 1`、`parameters: {}` 和 `size: {width, height}`。不是 `typeID`／`instanceID` 欄位。目前十五種組件不接受 parameters；收藏排序／來源及直播篩選、列表密度屬實例私有呈現狀態，不寫入分享 Layout。詳情／設定／Torrent、關注動態、Bilibili 推薦影片、YouTube 瀏覽、繼續觀看與垂直推薦流均可加入作者 Layout；舊包仍有效，固定命令不覆寫作者佈局。

`page.motion` 使用 JSON 物件，例如 `"motion": {"duration": 0.25, "opacity": 0, "offsetX": 0, "offsetY": 16, "scale": 1, "curve": "easeOut"}`。這六欄都必需，數值／曲線限制與上述 XML 相同，但 **JSON 不含 `version`**；未知欄位、null、錯誤型別及超限值會拒絕。整個 `motion` 欄位可省略，舊 Layout 解碼為 none（`duration: 0, opacity: 1, offsetX: 0, offsetY: 0, scale: 1, curve: "easeOut"`）；此時可繼承 Skin 預設。基礎 pages、斷點 pages 與 tabs 內頁都使用同一格式，分享保存它們的自訂動效；範例作者 Layout 省略 motion，讓 Skin XML 生效而不將預設烘焙回 Layout。

可選展示欄位 `homePageID`（UUID）指定首頁；`hiddenPageIDs`（UUID 陣列）隱藏導覽頁；`collapsedInstanceIDs`（UUID 陣列）折疊組件。省略時首頁使用 App 預設、隱藏／折疊集合為空。首頁與隱藏 ID 必须存在於基礎或斷點 pages，折疊 ID 必須是實際 component instance；隱藏不是刪除頁面或業務資料。範例省略這些選項，保留全部頁面可見。

node kind 與其他欄位：`empty` 無額外欄位；`grid` 用 `columns`；`horizontalStack`／`verticalStack`／`group` 用 `children`；`split` 用 `first`, `second`, `ratio`（0 < ratio < 1）；`tabs` 用 `pages`, `selectedPageID`；`component` 用上述組件欄位。容器不可空。id 在一變體中不得重複；跨斷點相同 component id 的型別／版本／參數需一致。breakpointLayouts 是 Swift Codable 非字串 key 字典的交錯陣列：`[{"minimumWidth":960}, [page, ...]]`；空為 `[]`，不是 `{}`。上限 32 pages／變體、512 nodes（含各變體）、32 深度；尺寸不得小於表列最小尺寸或大於 8192；斷點寬度 320…10000、不得重複；parameters JSON 上限 16384 bytes。

Layout 只包含展示結構，不含私人查詢、帳號、作品／任務內容、簽名 URL 或本機路徑。分享衍生包可明確選擇不帶 Layout、目前 Layout 或作者 Layout；經 `WorkspaceLayoutCodec.sanitizedForSharing` 與 store 匯出遞迴清除所有 component parameters（含斷點），保留合法展示結構和首頁／隱藏／折疊資訊。不要直接壓縮偏好目錄。

## 資源與安全 limits

| 資源 | 上限 |
| --- | --- |
| ZIP | 65 MiB；256 entries，含目錄項 |
| 展開單檔／全包 | 16 MiB／64 MiB，按實際輸出檢查 |
| 每份 JSON 文件 | 1 MiB |
| pageMotion XML | 16 KiB，僅明列 `entryPaths.pageMotion` 時載入 |
| PNG／JPEG | 每檔 16 MiB；每邊 ≤8192、總像素 ≤64,000,000；需實際解碼成功 |
| TTF／OTF | 每檔 16 MiB；需符合內容 magic 及 CoreText 解碼，font ID 必需授權歸屬 |
| 解碼圖片快取 | 48 MiB，按目標呈現大小縮圖 |

拒絕 symlink／hardlink、非普通檔案、重名、越界路徑、加密、ZIP64／分卷、CRC 錯誤、巢狀壓縮、SVG／HTML、執行檔與 `.js`／其他腳本。**本格式不支持 JavaScript，安裝／重載 Skin 不授予執行權**；隔離 Layout helper 的內部研究不是對外 Skin 腳本入口。無音效、影片背景、shader 或原生控件程式替換。

## 分享與授權

兩包 JSON、XML、展示圖和幾何素材均為本範例原創，使用 [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) public-domain dedication；manifest 的 license 及每素材 attribution 保存同一聲明，可修改及再散布。工具程式遵循 repository 軟體授權；CC0 聲明不覆蓋 repository 的其他程式或第三方內容。未隨附字體，正文不烘焙成圖片。

作者／授權 metadata 是宣告而非身份、權利或安全簽章。替換素材前需確認再散布權；打包成功不等於取得授權。作者原包匯出保留原 ID；含個人外觀／選定 Layout 的衍生包生成新 ID，保留原作者、原授權、來源 ID／digest。相同 ID／同內容匯入去重；不同內容需明確差異確認，不是自動作者更新。移除 Skin 不刪除已獨立套用的 Layout 或使用者資料。
