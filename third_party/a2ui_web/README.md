# third_party/a2ui_web — 官方 A2UI Web 渲染器的离线打包（spike）

把**官方** A2UI Web 渲染器（`@a2ui/web_core` + `@a2ui/lit`）打成一个**自包含、零外联**的
HTML 页面，产物提交在 `app/assets/a2ui_web/`，供 Flutter WebView 以 `loadHtmlString`
加载。这是**可复现 spike**：原生 `a2ui_flutter` 仍是产品默认渲染器，本目录不参与产品
默认路径（决策记录见 `docs/plan-a2ui-web-spike.md`）。

## 版本（2026-11-18 用 `npm view` 固定）

| 包 | 版本 | 说明 |
| --- | --- | --- |
| `@a2ui/web_core` | **0.15.0** | 协议核心（MessageProcessor / SurfaceModel / basic catalog） |
| `@a2ui/lit` | **0.15.0** | 官方 Lit 适配器（`A2uiSurface` + basic catalog） |
| `esbuild` | 0.28.2 | 构建工具（devDependency，不进产物） |
| `happy-dom` | 21.0.4 | 构建期 DOM 探针（devDependency，不进产物） |

候选对比（同日 `npm view` 实测）：`@a2ui/react` 0.15.0 可用；`@a2ui/angular` 最新仍是
**0.14.0**（没有与 core 0.15.0 同轨的版本）。选 Lit 的理由：产物最小（无 React/ReactDOM/
JSX runtime）、适配器与 core 同版本线、`A2uiSurface` 是版本无关元素，能直接吃
`web_core` 的 v1.0 basic catalog（见下）。

## 构建与探针

```bash
cd third_party/a2ui_web
npm ci            # 严格按 package-lock.json 安装（0.15.0 精确锁定）
npm run build     # 打包 + 写入 app/assets/a2ui_web/ + 自带 DOM 探针
```

`npm run build` 做的事：

1. 校验 `node_modules` 里 `@a2ui/web_core` / `@a2ui/lit` / `esbuild` 版本与 `package.json`
   的精确 pin 一致，漂移即失败；
2. esbuild 从 stdin 打包页面运行时（`format=iife`、`minify`、`target=es2020`、
   `legalComments=none`），**不产出动态 import**；
3. 静态守卫：bundle 里除 `a2ui.org`/`json-schema.org`/`example.*`/`www.w3.org` 这些
   **纯标识符**外不许出现外部 URL；出现 `fetch(`/`XMLHttpRequest`/`importScripts`/
   `sendBeacon`/`new WebSocket` 直接失败；
4. 把 bundle 内联进 HTML，按**内联脚本内容**算 sha256 写进 CSP（`script-src 'sha256-…'`，
   不用 `'unsafe-inline'`），CSP 只经 `<meta http-equiv>`（file/loadHtmlString 没有响应头）；
5. 产物：`index.html`（自包含页面）、`a2ui_web.js`（同一 bundle 的独立审计副本）、
   `fixture_surface.json`（页面启动即渲染的 v1.0 fixture）、`build-manifest.json`
   （版本、CSP、逐文件 sha256、`bundledPackages` 精确清单）；
6. `--probe`（默认开启）用 happy-dom 加载**产出的 HTML 结构 + 产出的 bundle**，断言：
   `ready` 事件、fixture 渲染出 `<a2ui-surface>`/`a2ui-basic-button`、正文含 fixture 文案、
   点击按钮后动作经 `A2uiBridge.postMessage` 回到宿主，且 `context` 已从数据模型解析
   （`choice: "a"`）。`node build.mjs --no-probe` 可跳过。

产物是**字节稳定**的（无时间戳、无主机路径）：连续两次 `npm ci && npm run build`
sha256 不变。

## 运行时页面 API（Dart ↔ 页面）

页面加载后立即向 `A2uiBridge` 发 `ready`，随后渲染内置 fixture；Dart 侧只通过
`window.A2uiWeb` 驱动：

| 方法 | 作用 |
| --- | --- |
| `A2uiWeb.render(messages)` | 灌入 A2UI 消息序列（数组或 `{messages:[...]}`），返回 boolean |
| `A2uiWeb.render(messages, {reset:true})` | 先清空再灌（.nonapp 打开用） |
| `A2uiWeb.reset()` | 销毁 processor 与全部 surface，重建空处理器 |
| `A2uiWeb.setTheme('dark'\|'light')` | 切换 `a2ui-dark`/`a2ui-light` 根类 |
| `A2uiWeb.fixture()` | 重置并重渲染内置 fixture |
| `A2uiWeb.stats()` | 调试：surface id / 渲染计数 / 版本 |

桥事件（JSON 字符串，经 webview_flutter 的 `addJavaScriptChannel('A2uiBridge')`）：

```jsonc
{"type":"ready","bridgeVersion":1,"protocol":"1.0","versions":{...},"catalogs":[...]}
{"type":"render_accepted","count":3,"surfaces":["spike"]}
{"type":"rendered","surfaceId":"spike","textLength":123,"text":"…"}
{"type":"action","name":"spike_confirm","surfaceId":"spike",
 "sourceComponentId":"confirm","timestamp":"…","context":{"choice":"a","source":"offline_preview"}}
{"type":"error","code":"render_failed","message":"…"}
{"type":"surface_removed","surfaceId":"spike"}
{"type":"reset"}
```

## 协议要点（spike 的实测结论）

- **v1.0 可用**：`@a2ui/lit` 的版本化入口只导出 v0.9 catalog，但 `A2uiSurface` 本身是
  **版本无关元素**，搭配 `@a2ui/web_core/v1_0` 的 `basicCatalog` 即可渲染 v1.0 消息
  （`version:"1.0"` + `createSurface`/`updateComponents`/`updateDataModel`）。探针实测通过。
- **v1.0 的动态值必须用 `@path` / `@call`**：v0.9 用 `path`/`call`。同一份 surface 用
  `{"path":…}` 在 v1.0 下不会解析（动作 context 会原样带回 `{"path":…}` 对象）；
  用 `{"@path":…}` 才会解析成数据模型的值。Dart 侧 `a2ui_core 0.7.0` 两种写法都接受并
  按输入形态回写——所以跨渲染器共享 `.nonapp` 载荷时，**v1.0 统一写 `@path`**。
- 页面同时注册 v1.0 与 v0.9 两个 basic catalog（组件实现是同一组 universal 元素，
  注册幂等），旧 v0.9 载荷也能渲染。
- 未接 `@a2ui/markdown-it`：其 0.2.2 的 peer 范围是 `@a2ui/web_core ^0.14.0`，与 0.15.0
  冲突；它是 Lit 适配器的**可选** peer，缺失时 Text 以纯文本渲染（控制台一条 warning）。
  如需 Markdown 渲染，等上游发 0.15 配套版本再接。
- 主题：basic catalog 的默认 CSS 用了 `light-dark()` / `color-mix()`（Safari 17.5+ /
  Chromium 111+）；更旧 WebView 会落到组件的硬编码 fallback 颜色，不影响功能。

## 离线与 CSP

```text
default-src 'none'; script-src 'sha256-<inline bundle>'; style-src 'unsafe-inline';
img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none';
base-uri 'none'; form-action 'none'; frame-ancestors 'none'
```

- **无 CDN、无外链**：页面不引用任何外部脚本/样式/字体；`connect-src 'none'` 封死网络。
- `style-src 'unsafe-inline'` 是 Lit 在 shadow DOM 里注入 `<style>` 的必要条件。
- `img-src` 只放 data/blob：surface 里指向 https 的图片会被拦（记录在案；.nonapp 需要
  图片时要么内联 data URI，要么由宿主显式放宽策略）。
- 构建期守卫 + 运行时 CSP 双保险；`build-manifest.json` 记录了 CSP 与文件 sha256。

## Flutter 侧的接入前提（未在本批次改动）

`app/lib/widgets/a2ui_web_card.dart` 通过 `rootBundle` 读
`assets/a2ui_web/index.html`；**`app/pubspec.yaml` 的 `flutter.assets` 需要加一行
`- assets/a2ui_web/`**（pubspec 归批次 01 所有，本批次不越界改）。未声明时卡片会回退到
仓库内文件路径（仅 debug/test 可用）并给出显式错误，不会静默白屏。

## 许可证

- 本目录代码：Apache-2.0（与上游 A2UI 一致，见 `LICENSE`）。
- 上游归因与随包依赖清单：`NOTICE`。
- 产物内联脚本的 banner 保留归因（不含 URL，避免与「零外链」静态门冲突）。
