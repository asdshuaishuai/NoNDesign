# ThreeUI Community 组件（vendored）

| 项 | 值 |
| --- | --- |
| 上游 | MengTo/threeui，ThreeUI Community |
| 版本 | 1.1.0（npm `@designcodeio/threeui@1.1.0`） |
| 来源 | `https://www.npmjs.com/package/@designcodeio/threeui` · `https://github.com/MengTo/threeui` |
| 许可证 | MIT，原文见同目录 `LICENSE`（Copyright (c) 2026 Meng To） |
| 字体 | 组件里内联的 Lexend 为 SIL OFL 1.1，原文见同目录 `FONT-LICENSES.md` |

## 取用与改动

本目录只放**自包含的单页组件**：每个 HTML 都内联了运行所需的脚本、样式、纹理与
字体，WebView 用 `loadFlutterAsset` 直接按文件打开，不读同目录其它文件、不发任何
网络请求（应用内校验见 `app/test/three_threeui_test.dart`）。

| 本地文件 | 上游路径 | 说明 |
| --- | --- | --- |
| `spark-badge.html` | `lib-dist/assets/spark-badge.html` | 原页引用了 ThreeUI 宿主注入的 `params` 变量，补一行 `new URLSearchParams(location.search)` 后可独立运行 |
| `thinking-button.html` | `lib-dist/shaders/neuform-isolated/sources/thinking-button.html.js` | 原样（取模板字符串里的 HTML） |
| `semantic-explorer.html` | `lib-dist/shaders/semantic-bloom/sources/design-f0ebbe02-7d8a-41fd-9041-a1124185c27b.html.js` | 原样 |
| `text-on-a-path.html` | `lib-dist/shaders/text-path-studies/sources/text-on-a-path.html.js` | 原样 |
| `glassblown-neon.html` | `lib-dist/shaders/neuform-isolated/sources/glassblown-neon.html.js` | 原样 |
| `audio-wordmark.html` | `lib-dist/shaders/neuform-isolated/sources/audio-wordmark.html.js` | 原样 |
| `gallery-heading.html` | `lib-dist/shaders/neuform-isolated/sources/gallery-heading.html.js` | 原样 |
| `creator-studio-intro.html` | `lib-dist/shaders/neuform-isolated/sources/creator-studio-intro.html.js` | 原样 |
| `text-on-a-path-ii.html` | `lib-dist/shaders/text-path-studies/sources/text-on-a-path-ii.html.js` | 原样 |
| `inner-green-3d.html` | `lib-dist/shaders/sylva-living-world/sources/inner-green-3d.html.js` | 把同包 `lib-dist/assets/landing-pages/inner-green-assets/` 里的 `three.min.js`、两张 jpg 与 `lexend-latin.woff2` 内联为单文件（原页用同目录相对路径，`file://` 下会被 CORS 拦） |
| `character-filmstrip.html` | `lib-dist/shaders/character-carousel/sources/character-filmstrip.html.js` | 原样 |
| `character-wave.html` | `lib-dist/shaders/character-carousel/sources/character-wave.html.js` | 原样 |

`catalog.json` 是 NaN 自写的画廊清单（名称/一句说明/缩略提示），不属于上游。

## 为什么挑 `shaders/*/sources/*.html.js`

`lib-dist/assets/*.html` 里有些页面依赖同目录资产或外网 CDN（例如
`complete-shelf-v2.html` 引 jsdelivr 与 Google Fonts）。运行时要离线、无端口、
WebView 直接开文件，所以选了上游这些**已经把 HTML 文档完整内联**的组件源页；
`lib-dist/assets/spark-badge.html` 本身是自包含的，作为三件套示例保留。

## 升级步骤

1. `npm pack @designcodeio/threeui@<新版本>`，按上表重新取模板字符串。
2. 保持每个文件自包含（不新增 `src=`/`url()` 相对路径或 https 外链），
   需要的话把同包资产内联进来。
3. 同步本 NOTICE 与 `catalog.json`，跑 `flutter test test/three_threeui_test.dart`。
