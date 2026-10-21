# IINA-ANI 功能圖標

40 個為現有功能繪製的圓角線性圖標。使用 24 × 24 網格、1.75 px 線寬及圓角端點，單色透明底；以 24 pt 為主要尺寸，16／20 pt 可在預覽頁檢視。

開啟 [互動預覽](preview.html) 可搜尋、切換明暗背景、改變尺寸與顏色；點選圖標可複製素材名稱。整套預覽：[淺色](preview-light.png)、[深色](preview-dark.png)。

## 檔案

| 路徑 | 用途 |
| --- | --- |
| `svg/` | 40 個可縮放原稿，使用 `currentColor` 著色 |
| `png/24/`、`png/48/`、`png/96/` | 透明底黑色 PNG，分別為 24、48、96 像素 |
| `manifest.json` | 圖標 ID、中文名稱、分類、Xcode 素材名稱對照 |
| `preview.html` | 可離線開啟的互動預覽 |
| `preview-light.svg`、`preview-dark.svg` | 可縮放總覽原稿 |
| `generate.mjs` | 幾何定義與匯出程式，執行環境需 Node.js 及 Sharp |
| `../../IINA-ANI/Assets/Assets.xcassets/FunctionIcons/` | 已加入現有 Asset Catalog 的 40 組 Template 向量素材 |

SVG 可在向量工具中繼續編輯；網頁內嵌 SVG 時可用 CSS `color` 著色。PNG 保留透明度，深色背景請使用向量著色或原生 Template 著色。

## 功能對照

| 分類 | 圖標 ID |
| --- | --- |
| 探索與導航 | discover、search、calendar、favorites、history、downloads、settings、open-link |
| 播放與彈幕 | play、pause、stop、next、playlist、danmaku、subtitles、live |
| 內容與來源 | work、episodes、bookmark、sync、source、subscription、account、quality |
| 下載與外觀 | torrent、magnet、folder、import、export、appearance、layout、delete |
| 通用操作 | add、close、check、back、refresh、filter、sort、info |

素材採用 `ani-` 前綴，例如 `ani-danmaku`。現有導航、搜尋、收藏、詳情、下載、BT、設定、Skin／Layout 命令，以及本地選檔與 JSPlayer 的重新載入／彈幕設定按鈕已使用這套素材。保留文字標籤與輔助使用名稱，選中、停用及強調色沿用原生介面狀態。

設定頁左側五個分類使用 20 pt 的 appearance、account、play、downloads、info 圖標，上圖下文置中、至少 56 pt 高、間距 6 pt，各列填滿預設 112 pt 寬的分類欄；放大字級時可依文字需要擴寬。分類與主側欄共用 `WorkspaceNavigationButton` 的無底框／整列高亮樣式，並隨內容捲動更新選取。

`WorkspaceIcon` 與 `NSButton.setFunctionIcon` 集中於 `WorkspaceSkinPresentation.swift`；側邊頁面導航採 32 pt 圖標在上、文字置中在下，移除側欄軟件名稱。側欄寬 112 pt，按鈕填滿左右各 8 pt 留白內的整列、至少 64 pt 高、間距 6 pt；未選取時無原生底框，選中／滑過／按下時整列高亮。Skin 明確指定的狀態背景與圖片優先。一般命令為 16 pt，JSPlayer 圖標按鈕為 18 pt。Skin 自訂 `iconAsset` 優先，導航自訂圖標亦以 32 pt 為載入目標；未指定或移除覆寫時恢復功能圖標。Skin 刷新保留上下排列；原生核取方塊、單選狀態及組件密度指示保持各自的狀態圖片。

## 重新匯出

在可載入 Sharp 的 Node.js 環境執行：

```sh
node Design/Icons/generate.mjs
```

Sharp 位於外部共用套件目錄時，可透過 `ICON_NODE_MODULES` 指定該 `node_modules` 目錄。修改 `generate.mjs` 的幾何定義後重新執行，會同步更新 SVG、PNG、素材與預覽；單獨修改匯出檔會在下次匯出時被覆寫。

本次新增圖標隨專案 [LICENSE](../../LICENSE) 授權。上游圖標與其 [授權資料](../../LicenseForIcons.pdf) 保留各自的既有聲明。
