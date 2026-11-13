# IINA Plugin Danmaku — IINA-ANI

这是 IINA-ANI 随包维护的插件源码，基于 [xjbeta/iina-plugin-danmaku](https://github.com/xjbeta/iina-plugin-danmaku)，原作者版权与授权保留在 `LICENSE`。

## 构建和安装

在 IINA-ANI 仓库根目录执行 `bash PackageDanmakuPlugin.sh`，离线生成可重现的 `IINA-ANI/iina-plugin-danmaku.iinaplgz`；Xcode 复制 App 资源前也会自动打包。需要 Python 3；固定的 CommentCoreLibrary、IINA 类型定义及其授权位于 `vendor/`，版本由锁文件记录。

通过 IINA-ANI「设置 → 播放与弹幕 → IINA 弹幕插件」安装／更新，或使用 IINA 的本地插件包安装入口，之后退出并重启 IINA。需要支持插件的 IINA 版本。当前封装为 **0.1.22-ani.1／build 128**，不配置会覆盖本次修改的上游自动更新入口。

## 显示与交互

- 保留来源颜色，或统一白色；来源没有颜色时默认白色。
- 分别开关滚动、顶部固定、底部固定弹幕。
- 悬停时只暂停该条弹幕，移开后继续；不暂停视频或其他弹幕。关闭悬停暂停后恢复鼠标穿透。
- 调整字体、字重、字号、速度及透明度。App 启播的会话在连接及设置变更时接收完整设置；独立打开本地 XML 使用插件自己的偏好。
- 渲染 helper 由 `IINA-ANI/WebFiles/Danmaku/danmaku-settings.js` 打包，不在此维护第二份实现。

**IINA 原生 UI 遮挡层级：无法修复（现有公开插件 API 限制）。** CSS 无法把 overlay WKWebView 移到 IINA 原生控制栏下方，本插件不修改 IINA 本体。原生 WKWebView 悬停／全屏的验证限制见仓库工作记录。

弹幕库：[CommentCoreLibrary](https://github.com/jabbany/CommentCoreLibrary)。
