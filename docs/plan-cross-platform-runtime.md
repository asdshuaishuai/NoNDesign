# 全平台运行时改造：WebView / wasm 宿主 / 3D 渲染（2026-11-20 定稿并落地）

> 状态：**批次 A + B1 已落地（2026-11-20）**；macOS 真实 WKWebView 已实跑通过，
> Windows WebView2 / Linux WebKitGTK 采用同一契约、待对应机器复验；wasm_run
> 仅保留为启动失败兜底（B4 退役未做）。方向仍以 [vision.md](vision.md)
> 「代码创造世界」为主。
>
> 落地锚点：
> - WebView：`app/pubspec.yaml`（`webview_all`）、`app/lib/widgets/three_workspace.dart`、
>   `hotapp_workspace.dart`、`video_player_surface.dart`、`video_clip_surface.dart`、
>   `a2ui_web_card.dart`；旧 `webview_windows` 与 `*_preview_win.dart` 已删除。
> - 引擎宿主：`app/lib/core/engine/engine_backend.dart`（接口）、
>   `webview_engine_host.dart`（生产主路径）、`app/assets/engine/engine_web_host.js`
>   （classic ABI JS 宿主）、`engine_host.dart` / `engine_worker.dart`（wasm_run 兜底）。
> - 契约测试：`scripts/engine_web_probe.mjs`、`app/test/engine_web_host_probe_test.dart`、
>   `app/integration_test/engine_webview_test.dart`。
>
> 三条用户裁决（2026-11-20）：① WebView 换成全平台可用库；② wasm 换成全平台方案，
> 或改用自家渲染引擎的 wasm SDK；③ flutter_scene 是否用于 3D 工作台由实现侧裁决。

## 0. 现状与目标

| 面 | 落地现状（2026-11-20） | 目标 |
| --- | --- | --- |
| WebView | `webview_all` 1.5.2：macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK 4.1、Android WebView；OHOS ArkWeb 有渲染面但离屏会话待上游 | 一套 API 覆盖全平台 |
| wasm 宿主 | **引擎 classic wasm + JS 宿主跑在离屏 WebView**（生产主路径）；wasm_run/wasmtime/wasmi 仅启动失败兜底 | 完全退役 wasm_run（B4） |
| 3D 工作台 | three.js（vendored）+ `webview_all` 预览；Linux/Windows 与 macOS 同路径 | 全平台可预览 |
| 视频/热应用 | `webview_all` 统一预览；Windows 专属 WebView2 分支已删除 | 同一适配层 |

## 1. 决策一（已落地）：WebView → `webview_all` 全平台

**结论**：采用 [`webview_all`](https://pub.dev/packages/webview_all) 1.5.2（MIT），
联邦实现覆盖 Android / iOS+macOS / Windows / Linux / OHOS / Web，API 与
`webview_flutter` 兼容，并提供 `OffscreenWebViewSession`——引擎宿主依赖它。

**落地内容**：
- `webview_flutter` / `webview_flutter_wkwebview` / `webview_windows` 全部移除；
  5 个消费文件换 import，`PlatformCapabilities.supportsInAppWebView` 改为
  「非 Web 即真」。
- Windows 的 `three_preview_win.dart` / `hotapp_preview_win.dart` 与
  `webview_windows` 依赖删除，统一走 `WebViewController`；Windows 能力矩阵测试改为
  「同样创建 WebView」。
- 测试替身改用 `webview_platform_interface` / `webview_all_wkwebview` 导出。

**风险与已验证项**：
- macOS 真实 WKWebView 已由 `integration_test/engine_webview_test.dart` 跑通
  （离屏会话 boot、render、human apply、session 复用）。
- Windows/Linux 尚未在本机复验；沿用同一 `OffscreenWebViewSession` 契约，
  需在对应机器跑同一 integration test。
- Linux 需随包分发 `webkit2gtk-4.1`（与 deepDesign Linux 打包同法）；Windows 沿用
  WebView2 运行时（Win10 1809+ 自带/可引导安装）。
- OHOS：`webview_all_ohos` 目前未实现 `supportsOffscreenWebViews`，引擎宿主会回落到
  wasm_run；补法是等上游或给 OHOS 走隐藏 `WebViewWidget` 宿主。

## 2. 决策二（已落地）：引擎 classic wasm 跑进 WebView，wasm_run 降为兜底

**引擎提供两种 wasm SDK（2026-11-20 核对源码/README）**：

| SDK | 产物 | 宿主要求 | 本项目裁决 |
| --- | --- | --- | --- |
| **classic** | `moonviz-wasm-classic-*.wasm`：纯 WASM MVP、0 imports、线性内存、`_in` 槽 ABI（`docs/wasm-abi.md`）；当前 805,952 B | 任何符合 WASM MVP 的运行时（wasmtime/wasmi/浏览器 WebAssembly），JSC/WKWebView、WebKitGTK、WebView2、Android WebView 全覆盖 | ✅ **全平台基线** |
| **wasm-gc** | `moonviz-engine-wasm` npm SDK：≈90KB，WasmGC + JS String Builtins，字符串直通 | Chrome/Edge 119+、Firefox 120+、Safari 18.2+、Node 22+（Node 24 更稳） | ⏸ 未来 V8/新 WebKit 快路径，**不作为全平台前提** |

**为什么不是换另一个原生 wasm 库**：原生路线「全平台」与「SIMD」不可兼得——
iOS 禁止 JIT，wasmtime/wasmer 类 JIT 不可用；wasmi 解释器不支持 SIMD；Windows 的
wasmtime 还因 cdylib 陷阱传输问题退回 pulley 解释器（慢 5–15×）。把 classic wasm
放进 WebView 后，四个平台都用自己的生产级 JS/wasm 引擎（JSC/V8），且不再有
平台动态库、FFI 构建钩子与 Windows `.dll` 加载问题。

**架构**：
- `EngineService` 面向 `EngineBackend`；`startAuto` 在非 Web 目标优先
  `WebViewEngineHost`，失败才回落 `EngineHost`（wasm_run），并把真因写日志。
- 离屏 `OffscreenWebViewSession` 常驻；页面内嵌
  `assets/engine/engine_web_host.js`，wasm 字节按 192KB 分块经
  `runJavaScriptReturningResult` 推入，`WebAssembly.instantiate` 后走 ABI 探针。
- Dart → JS 单入口 `__ndEngine.<method>(b64…)`；返回 JSON 信封。Dart 不解语义。
- **隔离与看门狗**：JS 调用在平台 Web 进程执行，不阻塞 Flutter UI isolate；
  看门狗超时即销毁离屏会话并重建（比原生宿主「杀 isolate 但无法解开 native 帧」
  更彻底）。WebView 无 fuel，`fuelSupported=false`。
- 启动自检：ABI 导出（78 / 53 session）为空即 `engine_unavailable`；单测/CI 走
  Node 的同一 JS 宿主（`scripts/engine_web_probe.mjs`），不依赖显示服务器。
- 性能预期：JS wasm 比原生 wasmtime 慢，但设计 op 毫秒级；macOS 实测 boot + 全链
  在集成测试内秒级完成。真机 p95 门槛仍按 `WasmRuntimeGate` 记录。

**为什么保留 wasm_run 兜底而不是立即删**：`app/test/engine_*` 的纯 Dart 契约测试
与无 WebView 的 CI 环境仍依赖它；等 Windows/Linux/移动真机复验完成后再执行 B4
（移除 `third_party/wasm_run` 与依赖）。**新功能不得依赖兜底路径**。

## 3. 决策三（不变）：本周期不引入 flutter_scene

**事实**：flutter_scene 0.24.3（2026）已是全平台 3D 引擎（Impeller/Flutter GPU，
glTF、PBR、动画、物理），但 **pre-1.0、minor 版本允许破坏性变更**，且它是渲染/
游戏运行时，**不含建模工具的交互层**（相机轨道、拾取、移动/旋转/缩放手柄、
参数化图元编辑都要自建）。

**结论**：3D 工作台继续用 three.js（vendored；`webview_all` 全平台预览），
**不在本周期把建模工作台重写到 flutter_scene**。保留两个未来入口：
① flutter_scene ≥1.0 且 API 稳定后，评估原生视口；② 原生缩略图/离屏渲染独立小项。

## 4. 施工批次（总表）

| 批次 | 内容 | 状态 |
| --- | --- | --- |
| A | WebView → webview_all 全平台：依赖/import/能力矩阵/测试替身 + Windows 分支删除 | ✅ **2026-11-20 落地** |
| B1 | JS 宿主 + `WebViewEngineHost` + `EngineBackend`；离屏会话生命周期；Node 契约探针 | ✅ **2026-11-20 落地** |
| B2 | 移动端（iOS/Android）与 Windows 启用 WebView 引擎 | 🟡 代码路径已通（`startAuto` + 移动门默认开）；真机 smoke 待补 |
| B3 | 桌面默认切 WebView 引擎（性能门槛达标后） | 🟡 macOS 已默认；Windows/Linux 待复验 |
| B4 | 移除 `wasm_run` / `third_party/wasm_run` / 原生库 | ⏸ 待 B2/B3 复验后执行 |
| C | 3D 原生化评估（flutter_scene 门槛） | 不排期 |

## 5. 明确不做 / 待观察

* 不引入 CEF（体积）、不引入 WPE 分支（运行时成本）。
* 不再新增第二套 WebView 依赖或 `Platform.isWindows` 的 WebView 分支。
* wasm-gc 只在未来做「V8/新 WebKit 快路径」评估；切换前必须证明
  Safari 18.2 以下与旧 WebKitGTK 的降级路径。
* flutter_scene 在 1.0 前不进入生产依赖。
* OHOS 离屏 WebView 缺口按 §1 记录，不静默降级。
