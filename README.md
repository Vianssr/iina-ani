# IINA-ANI

English · [繁體中文](docs/README.zh-TW.md)

IINA-ANI is a macOS app for finding anime, keeping track of shows, and watching episodes in IINA or mpv. It brings Bangumi's catalog and airing schedule together with video sources, on-screen comments (danmaku), favorites, and downloads. A companion app for iPhone and iPad uses an embedded mpv player.

IINA-ANI is an unofficial fork of IINA+. It retains the upstream site resolvers, player integrations, and Huya proxy. The project is independent of IINA, IINA+, and Animeko. [Upstream repository](https://github.com/xjbeta/iina-plus)

## Getting started on macOS

The app targets **macOS 13.5 or later**. Testing on the minimum OS and on Intel hardware is incomplete. Install **IINA** or **mpv** for external playback. To show danmaku in IINA, install the bundled danmaku plugin. **FFmpeg** is required to package HLS downloads. Direct file downloads work without it.

To build from source, use Xcode with Swift tools 6.4, Node.js with npm, and Python 3. From the repository root, run the following commands to install the web dependencies, package the plugin, and build the Debug app.

```sh
bash InstallDeps.sh
xcodebuild -project IINA-ANI.xcodeproj -scheme IINA-ANI \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
```

The Debug app is at `.build/xcode/Build/Products/Debug/IINA-ANI.app`. Version `0.10.1` is a development build with no independent update service, release signing, or notarization. Its bundle ID is `com.LlS.iina-ani`, but it still uses the upstream Core Data directory. Avoid running it alongside IINA+ or mixing their data. The app does not automatically migrate preferences, logins, or files tied to the old bundle ID. [Build guide (繁體中文)](docs/USER_GUIDE.md#建置)

## Discovery and search

- **Anime.** The home page shows trending titles from Bangumi, Continue Watching, and paginated recommendations. Click a title for details. The seven-day calendar shows when episodes air. Availability on a particular video source can lag behind the broadcast.
- **Search.** Search Bangumi for anime, or search enabled video and live-stream sources that offer search. You can also paste a title or video URL.
- **Bilibili.** Browse your following feed or the recommendations page. Both support refresh and pagination. Opening a multi-part video starts the selected part, and you can switch parts, quality, or players.
- **YouTube.** Browse the home feed, search, copy a link, or open a video in your browser. In-app YouTube playback is unavailable. Guest users may need to search before the home feed shows results.
- **Identify a scene.** Choose **Navigate → Search by Screenshot…** (⇧⌘I) or use the button beside the search field. Select or paste an anime screenshot, then choose **Upload to trace.moe and Search**. Matches include the title, episode, timestamp, and similarity score. You can preview a clip, open AniList, or search for the title in the app. A match does not guarantee a playable source.

## Title details and episode selection

Each title has a synopsis, rating, tags, collection statistics, related titles, people, and comments. Open a section for more detail. Comments are read-only and can be browsed as an automatically loading list or a horizontal row of cards with manual loading.

- Browse regular episodes, specials, openings, and endings separately. Episodes known to be unaired are disabled. If Bangumi lacks an episode name or air date, you can still check sources for it.
- Select an episode to find a stream. A saved match for that exact episode takes priority. The app can open a single reliable match directly and lets you choose when there are several.
- Choose a stream, quality, and player. Source diagnostics identify missing episodes, wrong seasons, disabled sources, and resolution failures. A failed match never silently switches sites or falls back to episode one.
- From the title page, you can edit its watch status, Bangumi association, and source details, add it to favorites, or download several episodes at once.

## Playback, danmaku, and watch history

- **Players.** IINA and mpv support episode, stream, and quality selection where the source offers them. The built-in JSPlayer handles web playback for specific supported sources. Use IINA or mpv for torrent streaming.
- **Danmaku.** Keep the original comment colors or use white, pause an individual comment by hovering over it, and choose which scrolling, top, or bottom comments to display. Font, size, speed, and opacity settings are shared by the bundled IINA plugin and the built-in renderer. Local videos can use XML comment files. IINA's plugin API limits how comments layer over its native controls. [Danmaku controls and limitations (繁體中文)](docs/USER_GUIDE.md#彈幕顯示與互動)
- **Continue Watching.** Progress comes from the player's reported position. The home page shows the most recently watched episode of each confirmed anime title. Resuming an online episode resolves the original source again. Resuming a local video reopens its file.
- **Next episode.** Choose **Navigate → Next episode…** to advance an active session manually. When an episode ends naturally, IINA or mpv can advance within the same source and episode group, keeping the stream and quality. You can turn autoplay off. Local playlists use natural filename order within the same folder.
- **Following an ongoing series.** A series stays in Continue Watching until the app confirms the full season is available and you finish its last episode. You can also remove an episode's progress yourself. Your videos, downloads, and favorites are preserved.

Live streams and torrents playing while they download do not advance automatically. Stopping playback, closing the player, or encountering an error also ends the session without advancing to the next online episode.

## Favorites and Bangumi sync

Favorites keeps titles and bookmarked links in separate lists. Both support searching, filtering, sorting, and editing. New episodes reported by a source appear above the saved titles.

- Save a title with or without a watch status. The five statuses are **Want to Watch**, **Watching**, **Watched**, **On Hold**, and **Dropped**. Adding a favorite or finishing playback leaves the status you chose in place.
- Sign in to Bangumi to sync the watch status of linked titles or import your online anime collection. Sync covers title-level status only. Watch positions, per-episode progress, ratings, and comments stay outside its scope.
- Changes are saved locally first. If you're signed out or a sync fails, retry from Favorites. Pending changes belong to the original account, and an older response cannot clear a newer edit.
- Imports match titles by Bangumi ID. They preserve existing sources, downloads, pending local changes, and local favorites absent from the online collection.
- Link bookmarks retain their original URL and source identity. Older bookmarks migrate into this list. Favorite rows highlight on hover and show a persistent outline for keyboard selection. Mouse selection supports editing, removal, and drag-to-reorder.

## Downloads and BitTorrent

### Downloading episodes

Open **Quick Download** from a title page, choose a source, select the episodes, then resolve their streams and quality before adding them to the queue.

- Supported inputs include direct file URLs and finite, DRM-free HLS video on demand. Live recording, DRM, SAMPLE-AES, and some low-latency HLS variants are unsupported. Download availability depends on the source.
- The Downloads page shows progress, speed, and time remaining when available. Pause, resume, or cancel a task, open a completed file in a player, or reveal it in Finder.
- New anime downloads are grouped by title identity so shows with identical names have separate folders. Completed episodes are marked as downloaded. Removing a task record and deleting its file are separate actions.
- Tasks survive restarts. Resume interrupted downloads manually. FFmpeg packages HLS into MKV, fetching segments again after a pause. Direct files can resume when the server supports it and the file identity still matches.

### Finding and streaming torrents

Search RSS feeds from the episode picker, open a magnet link, or import a local `.torrent` file. Searching alone starts no peer-to-peer traffic. Select a result and its video files to begin.

- Download multiple files in a batch, or watch a selected file as it downloads in IINA or mpv. Tasks for the same torrent share a transfer and keep individual download records.
- Before starting P2P, consent to uploading and set a positive upload limit. Completed tasks stop seeding. Import private torrents from a local torrent file so their restrictions are respected.
- Metadata retrieval and uninterrupted playback depend on tracker and peer availability.

## Workspace and appearance

The macOS workspace brings discovery, search, title details, favorites, downloads, settings, and torrents into a single customizable window.

### Layouts

Open the layout editor in the main window to add components, organize pages, drag and resize items, or collapse sections. Combine horizontal and vertical containers, tabs, and columns. Drag the dividers to change column proportions. Reducing the column count merges the contents into the remaining columns.

Layouts support width breakpoints, undo and redo, and restoring the built-in draft. Choose **Save and Finish** to keep your edits or cancel to discard the draft. Pages support fade, slide, and zoom transitions and can import animations in a restricted XML format. [Page animation examples](Examples/PageMotions/)

### Skins

Import, preview, apply, or export a theme as an `.aniskin` file. A skin can define light and dark appearances, typography, colors, spacing, assets, and component states. Applying a skin keeps your layout unless you explicitly choose the author's layout. You can override a skin locally or export a customized copy. Skin and layout packages exclude account credentials, favorites, and history.

Cover transitions on title pages include slide-and-zoom, a cinematic push-in, and an iris reveal. They can be disabled and respect the system's Reduce Motion setting. [Skin authoring guide and examples (繁體中文)](Examples/Skins/README.md) · [Skin user guide (繁體中文)](docs/SKIN_GUIDE.md)

## Sources, accounts, and language

- The macOS app includes resolvers for Bilibili, Bilibili Live, Douyu, Huya, Douyin, and NetEase CC, along with configurable anime sources. Search, playback, danmaku, and downloads are separate capabilities. Site restrictions, account permissions, verification pages, expired media, and network errors can affect each independently. The app respects source access controls.
- To add anime sources, open **Settings → Sources & Accounts → Source subscriptions…**, enter a public HTTPS subscription URL, and preview the changes before applying them. Subscriptions can update public search rules for existing sources or import new sites as static configurations. Enable new sources manually to search their catalogs and resolve direct media links. The app does not execute remote playback scripts.
- You can sign in to Bilibili, Douyu, and Bangumi or sign out from Settings. The YouTube page offers a one-time, consent-based cookie import from a selected Chrome or Safari profile, subject to system permissions. You can also import a `cookies.txt` file manually.
- Search Settings for playback, danmaku, sources, accounts, downloads, appearance, and layout preferences. The interface supports **English, Traditional Chinese, and Simplified Chinese**, or can follow the system language. A language change takes effect the next time the app opens.

### Configure Bangumi sign-in on macOS

If you build the app yourself and want Bangumi sign-in, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`. Enter your own OAuth application's `BANGUMI_CLIENT_ID` and `BANGUMI_CLIENT_SECRET`, set the callback to `iina-ani://bangumi/oauth`, and rebuild. Features that do not require sign-in work without this configuration.

The local configuration is excluded from Git. Anyone with the built app can extract its client secret. Use the OAuth application's secret in that field and keep personal access tokens, cookies, and credential-bearing logs private.

## iPhone and iPad

Open `iOS/ANI.xcodeproj` and select the `ANI` scheme to build the companion app for **iOS 17 or later**. It includes Bangumi discovery, a local library, and an embedded mpv player with subtitles, danmaku, speed controls, episode selection, and double-tap seeking.

- **Library and playback.** Search, filter, or sort titles by watch status. The library migrates older formats and caches previously loaded details and episode lists for offline browsing. Import a full source configuration in JSON and save an exact episode match. Continue Watching saves the player's position and resolves that same episode again after a restart. Missing episodes, changed configurations, or disabled sources stop the attempt. Local files use bookmarks and can be reselected and verified if access expires. Manually entered HTTPS media URLs stay out of watch history.
- **Next episode and attachments.** Advance manually or enable same-source autoplay, which is off by default. Backgrounding the app, closing the player, or encountering an error does not trigger autoplay. Subtitle and danmaku attachments are kept per episode. Display and filter preferences survive restarts.
- **Sources.** The shared `SourceRuntime` supports 17 desktop CSS1 sources through 16 native adapters and a full configuration for `fqdm`. The default subscription (`https://sub.creamycake.org/v1/css1.json`) updates local search rules after you review and confirm the changes. You enable each source manually. Subscriptions preserve the native playback resolvers. Other public HTTPS subscriptions can add v4 static sources for search, episode selection, and direct media resolution. Legacy v3 `webSelector` configurations and mappings are retained in a disabled state.
- **Accounts and comments.** A Bangumi personal access token enables account-specific watch-status sync, collection import, and retry. Title details include tags, related works, characters, staff, and read-only short reviews. The app also supports automatic source matching, subscription previews, and separate link bookmarks. Automatic danmaku requires an explicit link to a public Bilibili XML file for the episode. The app checks the video IDs (`aid` and `cid`) and XML `chatid` before attaching comments. You can also import comments manually or turn them off.

Desktop-specific resolvers, site logins, downloads, the local BitTorrent engine, and workspace skins and layouts remain macOS features. The mobile app can connect to your own TorrServer for torrent playback. [iPhone and iPad guide (繁體中文)](docs/IOS_GUIDE.md)

The cross-platform baseline covers macOS, iPhone, and iPad. The project records app testing, real-source streaming, physical iPhone tests, core VoiceOver checks, and manual narrow-window checks separately. TestFlight and signed release builds are unavailable. [Cross-platform milestones (繁體中文)](docs/planning/MULTIPLATFORM_BASELINE.md) · [Verification history and limitations (繁體中文)](docs/history/WORK_LOG.md)

## Documentation and licenses

The detailed project guides are in Traditional Chinese.

- [macOS user guide and build instructions](docs/USER_GUIDE.md)
- [iPhone and iPad user guide](docs/IOS_GUIDE.md)
- [Project architecture, data storage, and release details](docs/architecture/PROJECT.md)
- [Cross-platform milestones](docs/planning/MULTIPLATFORM_BASELINE.md)
- [Verification history and limitations](docs/history/WORK_LOG.md)

IINA-ANI retains the upstream authors' credits and copyright notices and is distributed under the GNU General Public License v3. Icons have a separate license. Native dependencies, other third-party components, and the external danmaku plugin retain their respective licenses. [GPL v3](LICENSE) · [Icon license](LicenseForIcons.pdf) · [Native dependency licenses](Native/licenses/)
