# IINA Plugin Danmaku — IINA-ANI

Maintained source for the plugin bundled with IINA-ANI, based on [xjbeta/iina-plugin-danmaku](https://github.com/xjbeta/iina-plugin-danmaku). Original copyright and license are retained in `LICENSE`.

Other language: [简体中文](README.zh_CN.md).

## Build and install

From the IINA-ANI repository root, run `bash PackageDanmakuPlugin.sh`. The offline, deterministic package is written to `IINA-ANI/iina-plugin-danmaku.iinaplgz`; Xcode also packages it before copying App resources. Python 3 is required. Fixed CommentCoreLibrary and IINA type definitions are included under `vendor/`, with their licenses and package lock.

Install/update through IINA-ANI's **Settings → Playback & Danmaku → IINA Danmaku Plugin**, or IINA's local plugin package installer, then quit and restart IINA. Use an IINA version with plugin support. This package is version **0.1.22-ani.1**, build **128**. It does not configure upstream automatic updates, which would replace these changes.

## Settings and behavior

- Preserve source colors or render all comments white. Missing source colors default to white.
- Independently show scrolling, top-fixed and bottom-fixed comments.
- Pause only the hovered comment; moving the pointer away resumes it. Video playback and other comments continue. Disable hover pause for mouse passthrough.
- Adjust font, weight, size, speed and opacity. App-managed sessions receive a complete settings snapshot on connect and on changes. Standalone local XML uses the plugin's own preferences.
- The renderer helper is packaged from `IINA-ANI/WebFiles/Danmaku/danmaku-settings.js`; do not maintain a second copy here.

**IINA native UI stacking: unfixable with the current public plugin API.** CSS cannot place the overlay WKWebView below IINA's native controls. This package does not modify IINA itself. Native WKWebView hover/fullscreen verification limits are recorded in the repository work log.

Renderer: [CommentCoreLibrary](https://github.com/jabbany/CommentCoreLibrary).
