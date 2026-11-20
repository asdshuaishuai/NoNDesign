# plan-a2ui-web-spike.md — 官方 A2UI Web 渲染器 spike（批次 14）

> 状态：**spike 完成（2026-11-18）** · 结论：官方 Web 渲染器能在 WebView 里跑通
> v1.0 surface 与动作回流，**但生产默认仍是原生 `a2ui_flutter`**；Web 渲染器只作为
> `.nonapp` 跨端备选保留，未接入任何产品路径（`a2ui_web_card.dart` 当前零引用）。
> 产物与构建脚本：`third_party/a2ui_web/`、`app/assets/a2ui_web/`；Dart 接入边界：
> `app/lib/widgets/a2ui_web_card.dart`；契约测试：`app/test/a2ui_web_spike_test.dart`。
>
> **对账注记（2026-11-20）**：本文关于「webview_flutter 只有 macOS/iOS/Android」
> 的平台覆盖判断**以当时为准**；同日合并的用户实现已让 Windows 的 3D/热应用预览走
> `webview_windows`（WebView2），Linux 仍无内嵌 WebView。**WebView 目标仍是
> `webview_all` 全平台**（批次 A stash 待恢复），见
> [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) §1。

## 0. 结论先行

1. **官方渲染器可用**：`@a2ui/web_core 0.15.0` + `@a2ui/lit 0.15.0` 打成单文件页面，
   在 macOS WKWebView 与 iOS 模拟器（iPhone/iPad）上经 `loadHtmlString` 加载，
   CSP（`script-src` 用内联脚本 sha256）正常放行，fixture surface 画出，按钮动作
   经 `A2uiBridge` 通道回流到宿主，`context` 已从数据模型解析（`choice: "a"`）。
2. **v1.0 协议可用，但有 wire 形态约束**：v1.0 的动态值必须写 `@path`/`@call`
   （v0.9 才是 `path`/`call`）。同一份 surface 用 `path` 在 v1.0 下不会解析。
   Dart `a2ui_core 0.7.0` 两种都接受并保留输入形态——跨渲染器共享 `.nonapp` 载荷时，
   **v1.0 统一写 `@path`**。
3. **不替换原生**：官方 Lit 适配器的版本化入口只发到 v0.9 catalog（v1.0 需要
   `web_core/v1_0` 的 basic catalog + 版本无关的 `A2uiSurface` 组合，见 §5），
   页面体积 ~0.53MB、WebView 平台覆盖（Linux/Windows 无 webview_flutter 实现）、
   手势/滚动交由浏览器内核等差异都决定了它只能是备选。
4. **AG-UI 不是渲染器**：本轮不引入、不混线，记录见 §9。

## 1. 范围

做：

- 用官方包构建**自包含、零外联**的 Web 页面，产物入库、可字节稳定重建；
- WebView 承载 + JS 通道 + Dart 侧事件解码/下发边界（可注入、可测）；
- 在真实 WKWebView（macOS + iOS/iPadOS 模拟器）上验证渲染与动作回流；
- 记录与原生 `a2ui_flutter` 的能力/体积/手势/离线差异，给出生产默认不切换的理由。

不做（本批次明确不做）：

- 不替换 `a2ui_card.dart` / `a2ui_flutter` 的默认路径；不改任何产品 UI 路由；
- 不做自定义 Catalog、不做 `.nonapp` 打包格式变更、不做 Markdown 渲染器接入；
- 不宣称 Android 真机/Windows/Linux 的应用内 WebView 可用（见 §7 未跑项）；
- 不自研协议或渲染器（只消费官方包）。

## 2. 版本与选型（2026-11-18 `npm view` 实测）

| 包 | 固定版本 | 角色 |
| --- | --- | --- |
| `@a2ui/web_core` | **0.15.0** | `MessageProcessor` / `SurfaceModel` / v1.0 + v0.9 basic catalog |
| `@a2ui/lit` | **0.15.0** | 官方 Lit 适配器（`A2uiSurface`，版本无关元素） |
| `esbuild` | 0.28.2 | 构建（devDependency，不进产物） |
| `happy-dom` | 21.0.4 | 构建期 DOM 探针（devDependency，不进产物） |

候选对比：`@a2ui/react` 0.15.0 可用；**`@a2ui/angular` 最新 0.14.0**（无与 core 0.15.0
同轨版本）。选 Lit：产物最小（无 React/ReactDOM/JSX runtime）、与 core 同版本线、
`A2uiSurface` 能直接消费 `web_core/v1_0` 的 basic catalog。

版本用 `package.json` 精确 pin，`build.mjs` 在打包前比对 `node_modules` 实际版本，
不一致直接失败；`npm ci` 只认 `package-lock.json`。

## 3. 产物与接线

`npm run build`（= `node build.mjs`，自带 `--probe`）写入 `app/assets/a2ui_web/`：

| 文件 | 大小 | 内容 |
| --- | --- | --- |
| `index.html` | 530,539 B | 自包含页面：CSP meta + 内联 bundle + 挂载点 |
| `a2ui_web.js` | 529,489 B | 同一 bundle 的独立审计副本 |
| `fixture_surface.json` | 2,088 B | 页面启动即渲染的 v1.0 fixture |
| `build-manifest.json` | — | 版本、CSP、逐文件 sha256/字节数、`bundledPackages` 精确清单 |

随包依赖（esbuild metafile 实测，全部打进 bundle）：`@a2ui/lit`、`@a2ui/web_core`、
`lit`/`lit-element`/`lit-html`/`@lit/reactive-element`/`@lit/context`、`@preact/signals-core`、
`signal-polyfill`、`signal-utils`、`zod`、`zod-to-json-schema`、`redos-detector`、`validate-color`。
许可证与归因见 `third_party/a2ui_web/LICENSE`、`NOTICE`。

页面 API（Dart 只经这层驱动）：

- `window.A2uiWeb.render(messages, {reset})` / `reset()` / `setTheme()` / `fixture()` / `stats()`；
- 桥事件（JSON）：`ready`、`render_accepted`、`rendered`、`action`、`error`、
  `surface_removed`、`reset`；通道名 `A2uiBridge`（与 webview_flutter
  `addJavaScriptChannel` 同名）。

Dart 侧：`A2uiWebCard`（页面控制器抽象 `A2uiWebPage`，生产实现
`WebViewA2uiPage` 用 `WebViewController.loadHtmlString`；导航白名单只放行
`about/data/blob`）。页面装载器 `A2uiWebBundle` 先读 `rootBundle`，未声明 asset 时
回退仓库文件路径（仅 debug/test），两者都不行就抛 `A2uiWebBundleException` 并显示
人话错误，不静默白屏。

通道就绪时序已核对：`webview_flutter_wkwebview 3.27.2` 的
`addJavaScriptChannel` 用 `WKUserScript(injectionTime: .atDocumentStart)` 注入
wrapper（`webkit_webview_controller.dart:435-437`），页面内联脚本运行时
`window.A2uiBridge` 已存在——首个 `ready` 事件不会丢。

## 4. 官方 Web 渲染器 vs 原生 `a2ui_flutter`

| 维度 | 官方 Web 渲染器（本次 spike） | 原生 `a2ui_flutter`（产品默认） |
| --- | --- | --- |
| 协议 | v1.0 可用（`web_core/v1_0` catalog + 版本无关 `A2uiSurface`）；适配器版本化入口只到 v0.9 | v1.0（`A2uiProtocolVersion.v1_0`，现有 `a2ui_card.dart` 同款） |
| 体积 | 页面 ~0.53MB（HTML 内联 bundle 与审计副本各一份，共 ~1.06MB / ~1.01 MiB） | Dart/AOT 包体增量（无独立页面文件） |
| 手势/滚动 | 浏览器内核原生滚动/输入法/长按菜单；与 Flutter 手势竞技场分离 | Flutter 手势体系内，与工作区/画中画同一套 |
| 主题 | basic catalog 的 CSS 变量 + `light-dark()`/`color-mix()`（WebKit 17.5+ 完整；更旧走 fallback 色） | `context.palette`/AppTheme 直接继承，无版本门槛 |
| 离线 | 构建期内联 + CSP `connect-src 'none'`，零外联 | 天然离线（无网络面） |
| 平台覆盖 | webview_flutter：macOS/iOS/Android 有实现；**Linux/Windows 无实现** | 全平台（Flutter 渲染） |
| 安全面 | 页面 CSP + 导航白名单 + 构建期 URL/网络原语扫描；surface 仍按官方 zod schema 校验 | 官方包内校验；无 WebView/JS 攻击面 |
| Markdown | 未接 `@a2ui/markdown-it`（peer 范围 ^0.14.0，与 0.15.0 冲突），Text 走纯文本 + 一条 warning | 原生 Text 渲染（无 Markdown 语义） |
| 维护成本 | 多一套 node 构建链 + 提交产物 + sha256 漂移门 | 纯 Dart 依赖 |

**裁决**：默认继续原生。Web 渲染器只在「`.nonapp` 需要在没有 Flutter 原生渲染器的
容器里打开」这类未来场景评估（且仅 macOS/iOS/Android），并且要先满足 §8 的前置。

## 5. 协议事实（实测，不是推测）

1. **v1.0 消息形状**：`{"version":"1.0","createSurface":{...}}` /
   `updateComponents` / `updateDataModel`（与现有 `.nonapp` v1.0 夹具同形）。
2. **动态值**：`DataContext.isDataBindingObject` 在 v1.0 只认 `@path`
   （v0.9 只认 `path`）；函数调用同理 `@call` vs `call`。用 `path` 时动作 context
   原样带回 `{"path":"/choice"}`，不会解析成值；用 `@path` 才得到 `"choice":"a"`。
   Dart `a2ui_core 0.7.0` 的 `DataBinding.fromJson` 两种都接受并记录 `useReserved`。
3. `@a2ui/lit` 0.15.0 的 `./v0_9` 入口 re-export 的 `A2uiSurface` 是**版本无关**元素
   （`src/index.js`），v1.0 的 basic catalog 由 `@a2ui/web_core/v1_0` 提供；两者组合
   在探针与真实 WKWebView 上都渲染成功。页面同时注册 v1.0 与 v0.9 catalog
   （universal 元素注册幂等），旧 v0.9 载荷也能渲染。
4. `@a2ui/markdown-it 0.2.2` 的 peer 是 `@a2ui/web_core ^0.14.0` → 0.15.0 不满足，
   本轮不接；它是 Lit 适配器的可选 peer，缺失只影响 Markdown 语义。

## 6. 验证记录（本批次实际执行）

| 检查 | 命令 | 结果 |
| --- | --- | --- |
| 构建 + DOM 探针 | `cd third_party/a2ui_web && npm ci && npm run build` | ✅ 产物写入；探针 `probe ok: 4 bridge events, action={"choice":"a","source":"offline_preview"}` |
| 字节稳定 | 连续两次 `npm ci && npm run build` 比对 sha256 | ✅ 四个产物 sha256 完全一致 |
| Dart 契约测试 | `cd app && flutter test test/a2ui_web_spike_test.dart` | ✅ 14/14 通过（产物自包含/版本锁/哈希、桥解码、卡片接线、导航白名单、超时与失败人话） |
| macOS WKWebView | 临时 Swift 程序（`/tmp`，未入库）：`loadHTMLString` + `WKScriptMessageHandler("A2uiBridge")` | ✅ `DOM: {"api":"object","surface":true,"button":true,"choice":true,...}`；`WKWebView SMOKE PASS`，action=`spike_confirm` context=`{"choice":"a","source":"offline_preview"}` |
| iOS 模拟器（iPhone 17 / iOS 27.2） | 临时 SwiftUI/UIKit app（xcodegen 生成工程，未入库）：加载同一 HTML | ✅ `failures: []`，`click: clicked`，事件 `ready/render_accepted/rendered/action`，context 已解析 |
| iPad 模拟器（iPad Pro 11 / iOS 27.2） | 同上 | ✅ 同上（`failures: []`） |

**未跑（如实登记）**：

- Android 模拟器/真机上的 WebView smoke（Gradle 侧问题见批次 00；本轮未构建 Android 包）；
- Windows/Linux 应用内 WebView（webview_flutter 无这些平台的实现）；
- 真实 iOS/macOS 设备（仅模拟器 + 本机 WKWebView）；
- 发布包（`.app`/ipa）内的 asset 装载（依赖 §8 的 pubspec 声明，本批次不改共享文件）。

## 7. 安全与离线边界

- **CSP 只经 meta**（file/loadHtmlString 没有响应头）：
  `default-src 'none'; script-src 'sha256-<内联 bundle>'; style-src 'unsafe-inline';
  img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none';
  base-uri 'none'; form-action 'none'; frame-ancestors 'none'`。
  脚本用哈希而非 `'unsafe-inline'`；`style-src` 的 `'unsafe-inline'` 是 Lit 注入
  shadow DOM `<style>` 的必要条件。
- **构建期守卫**：bundle 里除 `a2ui.org`/`json-schema.org`/`example.*`/`www.w3.org`
  纯标识符外不许出现外链；`fetch(`/`XMLHttpRequest`/`importScripts`/`sendBeacon`/
  `new WebSocket` 出现即失败。
- **运行期守卫**：Dart 侧导航白名单只放行 `about/data/blob`；桥消息上限 1MiB；
  下发的 surface 一律 `jsonEncode` 作为 JS 表达式参数（不拼 HTML）。
- `img-src` 只放 data/blob：surface 指向 https 的图片会被拦。`.nonapp` 需要图片时
  要么内联 data URI，要么由宿主显式放宽策略（本例故意不放开）。
- surface 消息仍是**不可信输入**：官方渲染器按 zod schema 校验；页面无法外联，
  XSS 面被 CSP 收紧（但仍不能把 WebView 当沙箱边界——见 §8）。

## 8. 未解决 / 前置（不解决就不该把 Web 渲染器接进产品）

1. **asset 声明缺口（阻塞生产装载）**：`app/pubspec.yaml` 的 `flutter.assets` 还没有
   `- assets/a2ui_web/`。pubspec 归批次 01 所有，本批次未越界改；未声明时页面只能
   从仓库文件回退（debug/test），发布包会显式报「离线预览页面不可用」。**接入前必须
   由 pubspec owner 补这一行。**
2. **Markdown**：等 `@a2ui/markdown-it` 出与 0.15.x 配套的版本再评估；当前 Text 是纯文本。
3. **平台覆盖**：webview_flutter 没有 Linux/Windows 实现 → Web 渲染器只能覆盖
   macOS/iOS/Android；跨端 `.nonapp` 若要求全平台一致，仍必须走原生渲染器。
4. **体积**：单页面 ~0.53MB，且 HTML 与审计副本各存一份（~1.06MB）。若要进包，
   考虑只保留 `index.html`（或运行时按 manifest 校验后裁剪审计副本）。
5. **主题/排版**：`light-dark()`/`color-mix()` 需要较新 WebKit；旧系统落到 fallback 色。
   若要在产品里用，需给 WebView 注入宿主主题变量（`setTheme` 已留钩子）。
6. **Android 真机**、发布包内 asset 装载、真实设备手势/输入法差异均未验证。

## 9. AG-UI（记录暂缓，不混入 A2UI 路线）

**AG-UI 不是渲染器。** 它是 agent ↔ UI 的**事件/传输协议**（运行事件、消息流、
状态同步），不提供组件目录、surface 模型或渲染实现。A2UI 解决的是「agent 生成的
声明式 UI 如何被渲染」，两者层级不同：AG-UI 可以承载 A2UI 消息，但引入 AG-UI
不会让 surface 渲染能力增加一分。

本轮决策：

- AG-UI **暂缓**，不新增依赖、不改传输层；聊天流仍走现有 `ai_sdk_dart` + Dart agent 循环；
- 未来若接 AG-UI，定位是「agent 运行时事件总线」，与渲染器选型（原生 vs Web）解耦，
  不得写成「A2UI 的替代/升级」；
- npm 上的 `@ag-ui/a2ui-middleware`/`@ag-ui/a2ui-toolkit` 属于 AG-UI 生态的桥接件，
  本轮不评估、不引入。

## 10. 复现

```bash
# 1) 构建 + 探针（产物写 app/assets/a2ui_web/）
cd third_party/a2ui_web
npm ci
npm run build

# 2) Dart 契约测试
cd ../../app
flutter test test/a2ui_web_spike_test.dart

# 3) 真实 WKWebView（macOS）smoke
#    临时 Swift 程序（不入库）：
#    - WKWebViewConfiguration + WKUserContentController.add(handler, name: "A2uiBridge")
#    - 注入 shim：window.A2uiBridge = { postMessage: m => webkit.messageHandlers.A2uiBridge.postMessage(m) }
#    - webView.loadHTMLString(html, baseURL: nil)
#    - 2s 后 evaluateJavaScript 检查 a2ui-surface/a2ui-basic-button/正文，
#      .click() 按钮，断言 handler 收到 ready/rendered/action
swift /path/to/wk_smoke.swift app/assets/a2ui_web/index.html

# 4) iOS 模拟器 smoke：xcodegen 生成一个单页 UIKit app，把 index.html 作为资源，
#    同样的 shim + loadHTMLString + evaluateJavaScript，结果写 Documents/smoke.json
xcrun simctl launch <booted-device> <bundle-id>
```

`npm run build` 的探针本身就是「页面能渲染 + 动作能回流」的最小回归；Dart 测试守住
产物自包含（CSP/哈希/零外链/版本锁）与宿主接线；真实 WKWebView smoke 守住
「CSP 哈希在 WebKit 里真的放行 + 官方渲染器真的画出来」。
