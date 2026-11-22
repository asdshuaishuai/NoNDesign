# 3D 沙箱执行面：vendored three-live 与双执行路径（批次 06；three-live 1.4.0 于 2026-11-19 引入，991afe2）

> **WebView 迁移（已落地，2026-11-20 批次 A/B1）**：应用内 WebView 已从
> `webview_flutter`（仅 macOS/iOS）迁到 `webview_all`（macOS/iOS WKWebView、
> Windows WebView2、Linux WebKitGTK、Android WebView），见
> [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) §1。本文描述的
> 沙箱契约、CSP 边界与双执行路径不变；迁移只换宿主库，不改 three-live 资产。
>
> **3dcodeverse harness 接入（2026-11-22 用户裁决，方案未施工）**：3D 工作台直接
> 采用 3dcodeverse 的 skill/harness 契约（plan/check/judge/score），执行面仍是本文的
> three-live 沙箱；Python/Blender/CadQuery/URDF 运行时不进入产品进程。3D 项目分
> `scene`（`scene.json` 事实源）与 `code`（`src/*.js` 事实源）两种 authoring 模式。
> 见 [research/3dcodeverse.md](research/3dcodeverse.md) 与
> [plan-creative-workbench.md](plan-creative-workbench.md) §4。

3D 工作台的执行面在 docs/ 里此前没有正式文档，契约只散落在代码注释里；本文把
**vendored 资产范围、双执行路径、CSP 放宽清单与安全边界、画廊组件来源**收拢到一处。
实现位置：`app/lib/core/three_service.dart`（服务面与预览组装）、
`app/lib/widgets/three_workspace.dart`（工作台）、`app/assets/three/`（资产）。

## 1. Vendored three-live 1.4.0：范围与来源

| 项 | 值 |
| --- | --- |
| 上游 | google/three-live，版本 1.4.0（npm `three-live@1.4.0`） |
| 文件 | `app/assets/three/vendor/three-live.min.js`（经典脚本，224,716 B） |
| 许可证 | Apache-2.0，原文在 `app/assets/three/vendor/THREE-LIVE-LICENSE` |
| 资源键 | `threeLiveAssetKey`（`three_service.dart:69`） |
| 取用说明与本地补丁记录 | `app/assets/three/vendor/NOTICE.md` |

**本地补丁（仅一处，必须保留）**：上游默认让沙箱 Worker 用 `importScripts` 装载自身
渲染库；`file://` 页面拿到的 blob 是 opaque origin，Worker 里装载会被拒、页面白屏。
补丁把渲染库源码经页面内 `#three-live-runtime` 片段的 `textContent` 传给 Worker
启动脚本，Worker 在场即跳过远端装载（细节与复现命令见 `vendor/NOTICE.md`）。
上游沙箱边界（脚本在 Worker 里编译、`postMessage` 白名单、移除网络/存储接口、
尺寸限额）原样保留。

**同步脚本勘误（2026-11-19 复核）**：`scripts/sync_three_assets.dart` 只锚定
**旧降级面的渲染库** `assets/three/three.module.js`（r160，sha256 + 字节数）与
`preview.html` 的离线纪律——它**不覆盖 three-live**，grep 全文无 `three-live`
命中。three-live 是一次性人工 vendor（`NOTICE.md` 记录了从 npm 包复现的两处
字符串替换步骤），**没有专属同步脚本**；升级它只能手工替换并核对字节与许可文件。

## 2. 双执行路径

预览页是自包含单文件（渲染库、场景、运行时在挂载时内联，`assembleThreePreview`
组装），应用内 WebView 按 `file://` 直接打开——零网络请求、零外部地址、零本地
服务。场景执行有两条路径（`three_workspace.dart:5-11`）：

1. **three-live 沙箱（默认）**：页面把场景脚本放进 vendored three-live 的
   `allow-client-scripts` 沙箱 Worker——真实执行，非截图/外链替身。模板带
   `/*__THREE_LIVE__*/` 与 `/*__SCENE_SANDBOX__*/` 两个占位；要求沙箱执行面却没拿到
   three-live 源码时**显性失败**（`asset_missing`，不产出占位未替换的白屏半成品，
   `three_service.dart:1430-1433`）。
2. **旧降级面（同页回退）**：沙箱被宿主拦掉或场景为空时，页面自动降到同一份 HTML
   里的内联渲染库直跑（r160 `three.module.js`，与预览模板同目录落盘并由
   `scripts/sync_three_assets.dart` 对账）。

两条路都经 `window.NON3D` 回传 **error / metrics / screenshot** 三类桥消息，驱动
六层推进的修复轮。截图证据有硬上限：单张解码后 8 MiB、一个项目累计 48 张
（`three_service.dart:81-91`），到顶拒绝新截图、已落盘的不删。

## 3. CSP 最小放宽清单与安全边界

场景代码由模型生成，属于**不可信输入**；预览页 CSP（`threePreviewCsp`，
`three_service.dart:1366-1380`）在热应用、连接桌面的资源页同一道门的基础上只放宽
两条：

| 指令 | 值 | 说明 |
| --- | --- | --- |
| `script-src` | `'unsafe-inline' 'unsafe-eval'` | 内联是自包含的前提；`'unsafe-eval'` 是**放宽项**——沙箱 Worker 要用 `new Function` 编译场景脚本 |
| `worker-src` | `blob:` | **放宽项**——沙箱 Worker 经 blob 创建 |
| `connect-src` | `'none'` | 关闭 fetch/XHR/长连接/上报等全部外联通道 |
| `default-src` | `'none'` | 其余资源（远端脚本/样式/图片/字体）一律不加载 |
| `frame-ancestors` | `'none'` | 不允许被任何页面嵌套 |

`file://` 页没有响应头，策略经 `<meta http-equiv>` 生效：`ensureThreePreviewCsp`
保证 meta 早于第一个脚本——模板自带 CSP 时原样保留，缺失时注入到 DOCTYPE 之后。

**安全边界小结**：页面自包含（零外联）是第一道防线，CSP 是第二道；沙箱内的
网络/存储/消息通道已被上游移除，本仓补丁不动这些边界；桥消息载荷在落盘前有
字节上限；渲染只允许同目录自包含资产，清单/路径一律按不可信输入校验。

## 4. 画廊组件：ThreeUI Community 12 个

应用内另有一块「ThreeUI 组件」画廊：vendored 自包含页面由 WebView 按资源键读取，
点开即真实运行（`three_workspace.dart:7-11`）。

| 项 | 值 |
| --- | --- |
| 上游 | MengTo/threeui，ThreeUI Community 1.1.0（npm `@designcodeio/threeui@1.1.0`） |
| 文件 | `app/assets/three/threeui/` 下 12 个自包含 HTML + `catalog.json` |
| 许可证 | MIT（`threeui/LICENSE`）；内联字体 Lexend 为 SIL OFL 1.1（`threeui/FONT-LICENSES.md`） |
| 清单健康区间 | 8–12 个组件（`threeUiMinComponents` / `threeUiMaxComponents`，`three_service.dart:469-474`）：小于 8 说明资产被裁掉，超过 12 说明清单没同步；不是硬门，由测试与 `threeUiCatalogHealth` 暴露 |

清单按不可信输入处理：字段缺失、id 不合法、文件不是同目录 `.html` 的条目直接
丢弃（`parseThreeUiCatalog`），绝不把 WebView 引到目录外或远端地址；全部条目都坏
时显性失败。每个页面内联了运行所需脚本/样式/纹理/字体，不发任何网络请求，
校验锚定在 `app/test/three_threeui_test.dart`；逐文件与上游路径的对应关系见
`threeui/NOTICE.md`。

## 5. 平台与验证

- 内嵌预览使用 `webview_all` 全平台（macOS/iOS WKWebView、Windows WebView2、
  Linux WebKitGTK、Android WebView）；Windows/Linux 真机复验待补；
  移动端另受 `ThreeWebViewGate` 约束（`three_workspace.dart:50-63`）：file:// 模块
  脚本在集成测试跑通前不启用，未通过时诚实降级为「用电脑上的连接桌面查看」，
  不让用户对着白屏等待。
- 「在文件夹中显示」只在桌面三平台出现，能力判断唯一来源是 `PlatformCapabilities`。
- 相关测试：`app/test/three_threeui_test.dart`（画廊）、3D 服务面/工作台测试、
  `scripts/sync_three_assets.dart` 的产物对账（旧渲染库锚点）。
