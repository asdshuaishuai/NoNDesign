# 全平台运行时改造：WebView / wasm 宿主 / 3D 渲染（2026-11-20 重设）

> 状态：**2026-11-20 合并用户实现后重设**。原「webview_all 全量替换」批次 A 中止，
> 现状采用 **webview_flutter + webview_windows 双插件**；Linux 仍无应用内 WebView。
> wasm 宿主迁移（§2）与 flutter_scene 裁决（§3）继续有效。
> 三条用户裁决（2026-11-20）：① WebView 换成全平台可用库；② wasm 换成全平台方案，
> 或改用自家渲染引擎的 wasm SDK；③ flutter_scene 是否用于 3D 工作台由实现侧裁决。
>
> 相关文档：[README.md](README.md)（总纲）· [plan-creative-workbench.md](plan-creative-workbench.md)
> （工作台 UI）· [wasm-run-vendoring.md](wasm-run-vendoring.md)（§2 的退役对象）。

## 0. 现状（2026-11-20 合并后）

| 面 | 现状 | 说明 |
| --- | --- | --- |
| WebView | macOS/iOS/Android：`webview_flutter` + `webview_flutter_wkwebview`；Windows：`webview_windows` 0.4.0（WebView2） | Windows 3D/热应用预览已应用内（`three_preview_win.dart` / `hotapp_preview_win.dart`，含 `NON3D` 桥垫片与 WebView2 消息流）；视频 mp4 内嵌仍限 macOS/iOS/Android；Linux 无应用内 WebView |
| wasm 宿主 | `wasm_run`（wasmtime/wasmi，FRB 动态库，vendored 15 平台） | iOS：wasmi 无 SIMD → 本地引擎不可用；Windows：自建 wasmtime DLL；原生库 9.7MB/平台 |
| 3D 工作台 | three.js（vendored）+ HTML 预览沙箱 | macOS/iOS/Android/Windows 可预览；Linux 降级 |

消费面：`video_player_surface.dart`、`video_clip_surface.dart`、`three_workspace.dart`
（含 Windows WebView2 分支）、`hotapp_workspace.dart`（含 Windows WebView2 分支）、
`a2ui_web_card.dart`；测试替身：`three_workspace_test` / `shelf_video_player_test` /
`nonapp_hotapp_mount_test` / `nonapp_offline_test`。

## 1. 决策一（重设）：保留双插件，不执行 webview_all 全量替换

**结论**：以用户已落地的实现为基线：

| 平台 | WebView 实现 | 状态 |
| --- | --- | --- |
| macOS / iOS | `webview_flutter` + `webview_flutter_wkwebview` | 现状 |
| Android | `webview_flutter`（Android WebView） | 现状 |
| Windows | **`webview_windows` 0.4.0（WebView2）** | 2026-11-20 落地；VS2026 STL1011 修复（5ac91fc） |
| Linux | 无应用内 WebView | 降级浏览器/路径；记录为缺口 |

**为什么不再走 webview_all**：
1. 用户已在 release 线落地 Windows WebView2（`ea64874` + `5ac91fc`），含桥垫片、真机冒烟与
   CMake 修复；再换 `webview_all` 会把全部工作台面重做一遍，收益只剩 Linux。
2. `webview_all` 是 2026-11 新包（1.5.x），API 虽兼容 webview_flutter，但替换面覆盖
   视频/3D/热应用/A2UI 五处控制器与测试替身，风险与收益不匹配。
3. Linux 内嵌 WebView 的真实需求尚未出现；将来需要时再单独评估：
   `webview_all`（WebKitGTK）/ `webview_cef`（CEF）/ `webview_all_linux`。

**处置**：原 `webview_all` 批次 A 的工作区改动已 `git stash`（消息
`webview_all batch A (paused 2026-11-20)`），不合并；补丁备份在
`/tmp/webview_all_batch_a.patch`，仅作为未来 Linux 方案参考。候选对比保留：

| 候选 | 结论 | 理由 |
| --- | --- | --- |
| webview_flutter + webview_windows（现状） | ✅ 采用 | 用户已实现并真机验证；Windows 补齐；无新依赖风险 |
| webview_all 1.5.2 | ⏸ 备选（不采用） | 唯一含 Linux/OHOS 的兼容替换，但新包 + 全量替换风险 |
| flutter_inappwebview 6.x | ❌ | 无 Linux；迁移面大 |
| zikzak_inappwebview_linux | ❌ | WPE 运行时；Ubuntu 24.04 需源码编译 |
| webview_cef | ❌ | CEF 330MB、Chromium 149、C++20 工具链 |


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

**平台覆盖（2026-11-20 重设）**：WebView 引擎载体在 macOS/iOS/Android（`webview_flutter`）
与 Windows（`webview_windows`）可用；**Linux 暂无内嵌 WebView**，因此 Linux 继续使用
现有原生 `wasm_run`。B4 的「完全退役」改为「**除 Linux 外退役**」；待 Linux WebView 方案
（`webview_all` / `webview_cef`）落地后再收尾。Windows 的 WebView2 离屏能力需在 B1 用
`webview_windows` 实测（其 API 与 `webview_flutter` 不同，适配层要独立）。

**迁移分批**（不搞一次性换心）：

| 批次 | 内容 | 验收 |
| --- | --- | --- |
| B1 | JS 宿主 + `WebViewEngineHost`（与 `EngineService` 同面）+ 离屏会话生命周期；macOS/iOS/Android 用 `webview_flutter`，Windows 用 `webview_windows` 适配 | 门面契约测试（mock JS 通道）+ SIMD 探针降级 |
| B2 | 移动端（iOS/Android）与 Windows 启用 WebView 引擎；macOS/桌面仍用 wasm_run | iOS 16.4+ 真机跑通 `_in` ABI；Windows WebView2 跑通；旧系统降级为「连接桌面」 |
| B3 | 桌面（macOS/Windows）默认切 WebView 引擎（性能门槛达标后），wasm_run 保留一版兜底 | 真机基准 + 全量契约探针 |
| B4 | 移除 `wasm_run` / `third_party/wasm_run` / 原生库（**Linux 除外**）；更新文档与能力矩阵 | 依赖树除 Linux 外零 wasm_run；打包体积下降 |

**测试策略**：纯 Dart 测试继续用 fake gate；真引擎契约测试走
「JS 宿主探针」（node 或 integration_test，视 B1 结果定）；删除以 wasm_run 为前提的
`wasm_run_spike_test` 一族时必须在 B4 统一回收。

## 3. 决策三（3D）：本周期不引入 flutter_scene

**事实**：flutter_scene 0.24.3（2026）已是全平台 3D 引擎（Impeller/Flutter GPU，glTF、
PBR、动画、物理），但 **pre-1.0、minor 版本允许破坏性变更**，且它是渲染/游戏运行时，
**不含建模工具的交互层**（相机轨道、拾取、移动/旋转/缩放手柄、参数化图元编辑都要自建）。

**结论**：3D 工作台继续用 three.js（vendored；macOS/iOS/Android/Windows 已有应用内预览，
Linux 降级），**不在本周期把建模工作台重写到 flutter_scene**。保留两个未来入口：
① flutter_scene ≥1.0 且 API 稳定后，评估原生视口（去掉 WebView 依赖）；
② 原生缩略图/离屏渲染（作品集封面、导出预览）可作为独立小项，不碰建模交互。

## 4. 施工批次（总表）

| 批次 | 内容 | 状态 |
| --- | --- | --- |
| A | WebView → webview_all 全量替换 | **中止**（用户已落地 webview_windows；改动 stash 保留作 Linux 参考） |
| B1–B4 | wasm 宿主迁移（§2） | 待排期；不再依赖批次 A |
| C | 3D 原生化评估（flutter_scene 门槛） | 不排期 |

## 5. 明确不做 / 待观察

* 不引入 CEF（体积）、不引入 WPE 分支（运行时成本）。
* 不同时维护第三套 WebView API；Linux 需要内嵌 WebView 时再单独评估。
* flutter_scene 在 1.0 前不进入生产依赖。
* Linux 内嵌 WebView 暂不支持（降级浏览器/路径）；这是已知缺口，不是静默降级。
