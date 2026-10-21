# 影音來源接入待辦

來源：<https://sub.creamycake.org/v1/css1.json>（2026-09-25）。依來源清單順序處理；接入規範見 `add-video-source` skill。

2026-10-08 修復驗證：App Debug 無簽署建置及 `bash Tests/run-w3-sources.sh` 通過。以下更新稀飯、嘀嗒、E-ACG、森之屋、櫻花、Hanime 與熱播的實際生產解析器／媒體驗證結果；其他項保留歷史紀錄，舊有「待統一構建」狀態以本段為準。本輪使用 FFmpeg 和安裝版 IINA 的無視窗 libmpv，不代表 IINA／mpv 應用視窗相容驗收；內建 JSPlayer、站方彈幕及未列樣本不宣稱已驗證。`[x]` 表示已接入且所列樣本通過，不保證所有遠端線路可播。

2026-10-09 W7：核對清單 18 項／17 个既有來源並接入搜尋，僅取已核對入口／選擇器，不匯入 Cookie、任意腳本或未知媒體規則；下載適配限定清單的受支援直連／有限非 DRM HLS，無帳號提供者使用 guest。Bilibili 額外接入官方搜尋頁，不新增下載。實際逐站結果、完整功能串接及未簽收帳號門檻見 FRONTEND_REFACTOR_PLAN.md §5.2。

稀飯 W7：接受站方 type=auto 的同一 AES-CBC 配置，真實第二條備用線第 2 集已播放、作品收藏／第二程序再播及完整 HLS 306 段下載／完成檔播放。嘀嗒 W7：只允許精確未過期 owned PNG→TS 代理下載；3071-7-1 實際 379／552 段後 mediaUnavailable，未宣稱完成或偷偷換源。來源能力不是全部遠端線路可用保證。


- [x] 稀饭动漫 — `dm1.xfdm.pro`：2026-10-08 恢復接入；修正原解析器直接交出舊 `play.xfvod.pro:8088` 位址的問題，改讀站方播放器配置，經 `player.moedot.net` 解析並解密每次回應的 AES-CBC 媒體。樣本 `https://dm1.xfdm.pro/watch/1477/1/1.html`／第 2 集均經本次建置 App 的 SourceRegistry→VideoDecoder 完整入口回應 200，保留標題、集數及舊番主線；App 交出的真實 HTTPS MP4 均由 libmpv 解碼 1920×1080 並播放超過 2 秒，首集另通過 FFmpeg 一秒解碼。新番 `3166`／`3541` 目錄可取得，但本輪部分播放頁仍逾時或回傳站方資料庫 DNS 錯誤，未宣稱全部線路可播。原生 IINA 操作遇到本機外掛未安裝提示，未完成 IINA／mpv 應用視窗驗收；內建 JSPlayer 與站方彈幕未接入。
- [x] girigiri愛動漫 — `ani.girigirilove.com`：番劇／播放頁、選集、繁簡中線路、直連 HLS 與書籤已接入；App 建置、實際頁面解析及兩條線路的 HLS 回應已驗證。尚未在 IINA／mpv 視窗實測播放；內建 JSPlayer 與站方彈幕未接入。
- [x] 嘀嗒影视 — `www.didahd.pro`（現跳轉 `www.didahd.xyz`）：修正 `4kvm` 分段主機已由 `/bk/` 增加 `/rc/` 路徑而被本機 HLS 代理拒絕的問題。生產解析器解析 `https://www.didahd.xyz/play/3071-7-1.html`，保留 BD1 第 1 集及九集目錄；啟動實際本機代理並完成 PNG→TS 解包，FFmpeg 解碼一秒、libmpv 取得 1920×1080 影格且 time-pos 超過一秒。其他加密線路及網盤未接入。
- [x] 叽哔动漫 — `www.jibi.cc`：詳情／播放頁、選集與兩條樣本 HLS 線路接入；實際頁解析與 FFmpeg 解碼已驗證。依清單要求暫不構建完整 App，IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] E-ACG — `www.eacg1.com`：修正現行 `/voddetails-<id>.html`／`/Comicplay/<id>-<線路>-<集數>.html` 路由及按實際播放網址辨識線路 ID，不再把頁籤位置當線路號；所選線路優先。樣本 `https://www.eacg1.com/Comicplay/69000-3-2.html` 經生產入口取得五組／60 集節點，所選第 3 線第 2 集保持不變；同集五線均由 FFmpeg 解碼一秒，所選線路由 libmpv 解碼至一秒以上。
- [x] 森之屋动漫 — `senfun.in`：修正電影使用 `hd` 而非 `ep...` slug 導致播放網址被拒絕；保留原本集數後綴身份及非法路徑拒絕。樣本 `https://senfun.in/voddetail/2025261963.html` 經生產入口解析至 `hd.html`，BFZY／LZZY／FFZY 三線均由 FFmpeg 解碼一秒，首線由 libmpv 取得 1920×1080 影格且播放超過一秒。其他作品與先前 YHZY／wjzy2 媒體問題未在本輪重測。
- [x] 风车影视 — `www.dongmandaquan.vip`（裸域亦辨識）：`/voddetail/<id>.html` 詳情頁、`/vodplay/<id>-<線路>-<集數>.html` 選集、逐線路公開 HTTPS HLS／MP4、書籤及外部播放器直連已接入；隔離編譯實際 Swift 解析器連線核對 `斗破苍穹 年番` 的 8 條選集線路、第 2 集 7 條直連媒體（騰訊外部頁不列為串流），兩條 HLS 由 FFmpeg 各解碼一秒。App Debug 無簽署建置完成；尚未在 IINA／mpv 視窗實測播放，內建 JSPlayer 與站方彈幕未接入；其他作品及線路未逐一驗證。
- [x] 去看吧 — `11kt.net`：詳情／播放頁、選集、逐線路直連 HLS／MP4 解析及書籤已接入（同站 `www.11kt.net`／`qkan8.com`／`www.qkan8.com` 網域一併辨識）；播放頁 `data-play` 編碼由隔離編譯的實際 Swift 解析器連線驗證 62 項檢查全數通過，樣本集的兩條 AES-128 HLS 線路、一條 MP4 線路及電影樣本 HLS 由 FFmpeg 各解碼一秒。依清單要求暫不構建完整 App，IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 海星动漫 — `www.haixingdmx.com`（同站裸域 `haixingdmx.com` 一併辨識）：詳情／播放頁、選集、逐線路（播放Ⅰ–Ⅵ）直連 HLS 解析及書籤已接入；播放頁取址的 `/playinfo` cookie 挑戰（`t1`／`k1` → `k2`／`t2`／`m2t`／`im`／`kr`）與十六進位回應解碼由隔離編譯的實際 Swift 解析器連線驗證 78 項檢查全數通過，涵蓋網址辨識、書籤 NSPredicate、liveInfo 在線／離線、多線路選集定位、decodeUrl 線路鍵名與錯誤路徑；樣本集五條線路與電影樣本兩條線路解析所得 12 份去重串流（六個媒體主機）全數由 FFmpeg 各解碼一秒（H.264／AAC）。站方播放器對含非 ASCII 路徑的線路會重複編碼致 404，本接入按 UTF-8 還原後可播。依清單要求暫不構建完整 App，IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 樱花动漫 — 新增 `www.yinghuabb.com`／裸域辨識及書籤分類，舊 `yinghua2.com`／`yinghuaaa.com` 網域仍可辨識；目錄使用現行網域。修正串流排序把未選線路放在所選線路前的問題。樣本 `https://www.yinghuabb.com/index.php/vod/play/id/79473/sid/7/nid/1.html` 經生產入口取得七線，所選 sid=7 保持第一；同集六線由 FFmpeg 解碼一秒，sid=7 由 libmpv 播放超過一秒。sid=1（5线）媒體解碼失敗，未宣稱修復該上游線路。
- [x] 嘀哩嘀哩 — `dilidili.io`：既有詳情／播放頁、選集、逐線路 HTTPS HLS／MP4 解析及書籤接入已核對；實際網站 `chainsmoker-cat` 詳情與第 12 集六條線路可讀，`/_get_play` 一條 HLS 線路由 FFmpeg 解碼一秒。依清單要求暫不構建完整 App；IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 新优酷 — `www.youknow.tv`：詳情／播放頁、逐線路選集、`player_aaaa` base64／百分比編碼的 HTTPS HLS／MP4、書籤及外部播放器直連已接入；實際 `九门` 詳情頁含 34 條線路，樣本第 2 集前兩線由 FFmpeg 各解碼一秒。App 尚待統一構建；IINA／mpv 視窗、其餘線路、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 番茄动漫 — `www.fqdm.cc`：詳情／播放頁、逐線路選集、`player_aaaa` 公開 HTTPS HLS／MP4、書籤及外部播放器直連已接入；實際 `老虎和兔子 第二季` 詳情頁有兩線六集，樣本第 2 集兩線各由 FFmpeg 解碼一秒。App 尚待統一構建；IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] hanime1_1080p — `hanime1.me`：修正影片頁已改用 `h3.video-details-wrapper`、不再含 `h1` 而造成整體解析失敗；標題亦可取 `meta[name=title]`。樣本 `https://hanime1.me/watch?v=408446` 經生產入口取得頁面實際提供的畫質，1080p MP4 由 FFmpeg 解碼一秒，libmpv 取得 1920×1080 影格且播放超過一秒。不推測頁面欠缺的畫質。
- [x] hanime1_720p — `hanime1.me`：共用上述已修復的解析器，按影片頁 `<source size>` 提供 720p；同一樣本 `408446` 的 720p 及 480p 均由 FFmpeg 解碼一秒。720p 未另行做 libmpv 或 IINA 視窗驗收。
- [x] wedm — `www.vdm5.com`：`vodetail_`／`dmplay_` 詳情及播放頁、跨線路選集、未受限 `player_aaaa` HLS／MP4 及書籤已接入；實際 `xinbaokemeng` 兩線（151／127 集）第 2 集 HLS 各由 FFmpeg 解碼一秒。App 尚待統一構建；IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 影视森林 — `www.hc34567.com`：`hcvoddetail`／`hcvodplay` 詳情及播放頁、跨線路選集、公開 `player_aaaa` HLS／MP4、書籤已接入；實際 `琅琊榜` 三線各 54 集，樣本第 2 集前兩線 HLS 各由 FFmpeg 解碼一秒。App 尚待統一構建；IINA／mpv 視窗、內建 JSPlayer 與站方彈幕未驗證或接入。
- [x] 热播之家 — `www.rebozj.pro`（現跳轉 `www.rebozj.cc`）：新增原生來源、選集／線路、書籤分類與外部播放器接入。公開 BBA／NBY 線路的 `encrypt=3` 密文交由站方 Artplayer，在隔離 WKWebView 取得真實 HTTPS 媒體；拒絕非站方頁面及非允許 CDN，網盤／付費／試看及其他未驗證加密線路不列入可播目錄，不以替換線路掩蓋失敗。樣本 `https://www.rebozj.cc/detail/3832.html` 的兩組目錄及實際 sid=4／sid=5 均由生產入口解析，兩線均通過 FFmpeg 一秒解碼及 libmpv 播放；取消解析後可重新解析。BBA 曾有媒體解碼失敗及 libmpv 等待逾時，後續均通過，故不保證遠端 CDN 每次可用；舊樣本 `3413` 未重測。
