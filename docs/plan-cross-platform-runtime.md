# 全平台运行时改造：WebView / wasm 宿主 / 3D 渲染（2026-11-20 定稿，分批施工）

> 状态：**方案定稿；批次 A 工作区已改但暂停（2026-11-20 用户叫停，未提交）**。
> 三条用户裁决（2026-11-20）：① WebView 换成全平台可用库；② wasm 换成全平台方案，
> 或改用自家渲染引擎的 wasm SDK；③ flutter_scene 是否用于 3D 工作台由实现侧裁决
> （本文 §3 给出结论与依据）。
>
> 相关文档：[README.md](README.md)（总纲）· [plan-creative-workbench.md](plan-creative-workbench.md)
> （工作台 UI 批次依赖 §1 的全平台 WebView）· [wasm-run-vendoring.md](wasm-run-vendoring.md)
> （现状实现，§2 的退役对象）。

## 0. 现状（改造前）

| 面 | 现状 | 问题 |
| --- | --- | --- |
| WebView | `webview_flutter` + `webview_flutter_wkwebview` | 仅 macOS/iOS 有实现；Windows/Linux 五个工作台面（视频播放/动效合成/3D 预览/热应用/A2UI）全部降级 |
| wasm 宿主 | `wasm_run`（wasmtime/wasmi，FRB 动态库，vendored 15 平台） | iOS：wasmi 无 SIMD，MoonViz 模块跑不起来 → 本地引擎在 iOS 不可用；Windows：需自建 wasmtime DLL（已修但仍是特例）；原生库 9.7MB/平台 |
| 3D 工作台 | three.js（vendored）+ HTML 预览沙箱 | 依赖 WebView；Windows/Linux 不可用（随 WebView 改造解决） |

消费面清单（改造必须全覆盖）：`video_player_surface.dart`、`video_clip_surface.dart`、
`three_workspace.dart`（两处控制器）、`hotapp_workspace.dart`、`a2ui_web_card.dart`；
测试替身：`three_workspace_test` / `shelf_video_player_test` / `nonapp_hotapp_mount_test` / `nonapp_offline_test`。

## 1. 决策一：WebView → `webview_all` 1.5.2

**结论**：采用 [`webview_all`](https://pub.dev/packages/webview_all)（MIT），联邦结构：
Android WebView / iOS+macOS WKWebView / Windows WebView2 / **Linux WebKitGTK 4.1** /
OpenHarmony ArkWeb / Web。API 与 `webview_flutter` 兼容（`WebViewController` / `WebViewWidget` /
`NavigationDelegate` / `JavaScriptChannel` 同名同形），并额外提供**离屏 WebView 会话**
（`OffscreenWebViewSession`）——这正是 §4 wasm 宿主需要的底座。

**候选对比**：

| 候选 | 结论 | 理由 |
| --- | --- | --- |
| webview_all 1.5.2 | ✅ 采用 | 唯一全平台（含 Linux/OHOS）且 API 兼容；新包但结构完整（六个平台实现 + 平台接口），支持离屏会话 |
| flutter_inappwebview 6.x | ❌ | 无 Linux 实现；Linux 需另配 zikzak/WPE 分支 |
| zikzak_inappwebview_linux | ❌ | WPE WebKit 2.50+ 运行时；Ubuntu 24.04 需源码编译 WPE，打包/CI 成本过高 |
| webview_cef | ❌ | CEF 330MB、Chromium 149 固定、C++20 工具链，单包体积不可接受 |
| 官方 webview_flutter + 分平台手接 | ❌ | 三套 API + 三份生命周期代码 |

**迁移面**（批次 A）：依赖替换 → 5 个文件换 import → WK 专属参数保留
（`webview_all_wkwebview` 导出同名 `WebKitWebViewControllerCreationParams`）→
`PlatformCapabilities.supportsInAppWebView` 改为「非 Web 即真」→ 测试替身换
`webview_platform_interface` / `WebKitWebViewPlatform` 来源 → 全量测试。

**风险与缓解**：新包（2026-11 发布 1.5.x）——钉版本、先跑全量测试与双平台构建；
Linux 需随包分发 webkit2gtk-4.1（与 deepDesign Linux 打包同法）；Windows 需 WebView2 运行时
（Win10 1809+ 自带/可引导安装）。

## 2. 决策二（wasm）：渲染引擎 wasm SDK 跑进 WebView，逐步退役 wasm_run

**结论**：用**自家 MoonViz 渲染引擎的 classic wasm + JS 宿主**（与 deepDesign 前端同源）
作为引擎执行面，宿主载体 = 离屏 WebView；`EngineService` 对外方法不变，新增
`WebViewEngineHost` 实现同一门面。

**为什么不是换另一个原生 wasm 库**：MoonViz 产物含 SIMD；iOS 禁止 JIT，wasmtime/wasmer
类 JIT 运行时不可用，wasmi 类解释器不支持 SIMD——**原生路线上「全平台」与「SIMD」不可兼得**。
而 WKWebView（Safari 16.4+）、WebView2、WebKitGTK 4.1、Android WebView（Chromium 91+）
都支持 WebAssembly SIMD。这是唯一真正的全平台方案，且复用的是我们自己的引擎 SDK。

**架构**：

* 离屏 `OffscreenWebViewSession` 常驻（应用启动后惰性创建）；页面内嵌 base64 的
  `moonviz.wasm` + JS 宿主（移植 deepDesign 前端的 `engSlotLoad` / 读字符串 / 会话缓存逻辑）。
* Dart → JS 单入口 `window.__ndEngine.call(fn, b64…)`，JS → Dart 经
  `JavaScriptChannel` 回包；全部是 canonical `.mbt.md` 字符串与 JSON 信封，Dart 侧不解语义。
* `WebViewEngineHost` 实现与现有 `EngineService` 相同的方法集（render / validate / apply /
  session / generate / tap / constrain / event / history / export / list_*），上层
  `LocalEngineGate`、store、agent 循环**零改动**。
* 启动自检：`WebAssembly.validate(<SIMD 探针>)`，失败则 `engine_unavailable` +
  「连接桌面」诚实降级（iOS 15 / 未更新的旧 WebKit 属此列）。
* 性能预期：JS wasm 比原生 wasmtime 慢，但设计 op 量级毫秒级；以真机基准为准
  （验收门槛：单 op P50 ≤ 8ms、连续 200 op 不降级；达不到则桌面保留原生宿主，见批次 C）。

**迁移分批**（不搞一次性换心）：

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| B1 | JS 宿主 + `WebViewEngineHost`（与 `EngineService` 同面）+ 离屏会话生命周期 | 门面契约测试（mock JS 通道）+ SIMD 探针降级 |
| B2 | 移动端（iOS/Android/OHOS）启用 WebView 引擎；桌面仍用 wasm_run | iOS 16.4+ 真机跑通 `_in` ABI；旧系统降级为「连接桌面」 |
| B3 | 桌面默认切 WebView 引擎（性能门槛达标后），wasm_run 保留一版兜底 | 真机基准 + 全量契约探针 |
| B4 | 移除 `wasm_run` / `third_party/wasm_run` / 原生库；更新文档与能力矩阵 | 依赖树零 wasm_run；打包体积下降 |

**测试策略**：纯 Dart 测试继续用 fake gate；真引擎契约测试走
「JS 宿主探针」（node 或 integration_test，视 B1 结果定）；删除以 wasm_run 为前提的
`wasm_run_spike_test` 一族时必须在 B4 统一回收。

## 3. 决策三（3D）：本周期不引入 flutter_scene

**事实**：flutter_scene 0.24.3（2026）已是全平台 3D 引擎（Impeller/Flutter GPU，glTF、
PBR、动画、物理），但 **pre-1.0、minor 版本允许破坏性变更**，且它是渲染/游戏运行时，
**不含建模工具的交互层**（相机轨道、拾取、移动/旋转/缩放手柄、参数化图元编辑都要自建）。

**结论**：3D 工作台继续用 three.js（vendored；WebView 全平台化后 Windows/Linux 一并解锁），
**不在本周期把建模工作台重写到 flutter_scene**。保留两个未来入口：
① flutter_scene ≥1.0 且 API 稳定后，评估原生视口（去掉 WebView 依赖）；
② 原生缩略图/离屏渲染（作品集封面、导出预览）可作为独立小项，不碰建模交互。

## 4. 施工批次（总表）

| 批次 | 内容 | 状态 |
| --- | --- | --- |
| A | WebView → webview_all：依赖/import/能力矩阵/测试替身 + 全量测试 | 工作区已改，暂停未提交（2026-11-20） |
| B1–B4 | wasm 宿主迁移（§2） | 待 A 完成 |
| C | 3D 原生化评估（flutter_scene 门槛） | 不排期 |

## 5. 明确不做 / 待观察

* 不引入 CEF（体积）、不引入 WPE 分支（运行时成本）。
* 不同时维护两套 WebView API。
* flutter_scene 在 1.0 前不进入生产依赖。
* Linux WebKitGTK 版本下限 4.1（Ubuntu 22.04+/Debian 12+）；更老的发行版不在支持范围。
