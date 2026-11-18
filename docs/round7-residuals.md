# 第七轮残留清单（批次 00 建立）

> 本文件把**外部清单的第七轮条目**（`nonapp-2` / `nonapp-5` / `shelf-2` 与
> `docs/plan-chat-stream-shell.md` 的 S2/S3/S4「残留」）逐项落到仓库事实、
> owner 批次与验收 gate。
>
> **口径警告**：全仓 `grep -rn "第七轮"` 无匹配（2026-11-18 实测）。外部标签
> `nonapp-2`/`nonapp-5`/`shelf-2` 在仓库里只以**代码注释的 review 标记**存在
> （如 `app/lib/core/nonapp_cache.dart:62` 的 `review nonapp-5`），不是一套
> 独立编号体系。本映射按注释标记 + 计划文档建立，**不把外部标签当代码事实**；
> 若上游清单的编号含义与本文不同，以本文引用的 `文件:行` 为准。

## 1. 逐项映射

| 外部条目 | 仓库事实（文件:行） | 现状 | owner | 验收 gate |
|---|---|---|---|---|
| **nonapp-2** Android VIEW / 冷启动 | `app/android/app/src/main/AndroidManifest.xml:41-66`（VIEW 后缀面 + mime 面 + SEND 两组 filter）；`app/android/app/src/main/kotlin/com/example/nondesign/MainActivity.kt:43-54`（`onCreate`/`onNewIntent` 入队）、`:56-65`（`queueFromIntent` + URI 归一） | 声明面与通道代码齐，但 **Android 构建从未通过**（计划文档 `docs/plan-chat-stream-shell.md:152` 已登记「未构建验证」；批次 00 实测见 §2）。冷启动「等 boot ready」有单测：`app/test/nonapp_offline_test.dart:392` | **07** | `flutter build apk --debug` 绿 + 真机/模拟器 VIEW 打开 `.nonapp`（含 content:// 拷贝）+ 冷启动队列回归 |
| **nonapp-5** CSP / 导航白名单 | `app/lib/widgets/hotapp_workspace.dart:41-63`（`hotAppNavigationAllowed`：仅 `file:`/`about:`/桌面同源放行）、`:197-199`（`onNavigationRequest` 接线）；`app/lib/core/nonapp_package.dart:856`（`injectNonAppCsp`）；`app/lib/core/nonapp_cache.dart:62-63`（离线 `file://` 注入同款 CSP） | 实现齐；纯函数面有单测 `app/test/nonapp_offline_test.dart:470`，Widget 面 `:244`（CSP meta）/`:253`（导航 prevent） | **07** | 上述单测 + 离线包对外请求被 CSP 阻断的实测（WebView 控制台无外联成功） |
| **shelf-2** 离线提示 / 原型移除 | `app/lib/widgets/portfolio_view.dart:715-733`（`shelf-offline` 离线条：区分「未连接」与「没作品」）、`:299/:306`（两处未连接 toast）、`:749`（空态文案）；测试 `app/test/shelf_layout_test.dart:160`、`app/test/shelf_three_delete_test.dart:252` | 语义已修（不再把「连不上」伪装成空态）；**文案仍是内部语境**——`:732` 原文「未连接服务器：热应用 / 视频 / 3D / 原型都需要桌面服务」，含「服务器/桌面服务」等禁用词 | **07** | `shelf_layout_test` + `copy_guard_test`（严格门）零命中；原型行在未连接时显式不可用而非点了失败 |
| **S2** macOS 播放 / seek | `app/lib/widgets/video_player_surface.dart:30-45`（有 baseUrl 走 `/video/mp4?path=`，离线走 `file://`）、`:121-124`（在文件夹中显示）；`server/video_media.py:1-40`（双根白名单 + `FileResponse` Range/206） | widget 测试只断言 URL、控制器参数与错误覆盖层；**macOS 真机播放/seek 未人工验收**（`docs/plan-chat-stream-shell.md:129`） | **08** | 桌面手工：播放、拖动 seek、断网错误覆盖层；自动化沿用 `test/shelf_video_player_test.dart` |
| **S2** Linux/Windows 文件关联 | `app/linux/` 仅 `CMakeLists.txt` + `runner/` + `flutter/`（无 `.desktop`、无 `MimeType=`）；`app/windows/runner/` 无注册表/ProgID 关联代码（grep 仅命中 `win32_window.cpp:21` 的主题键） | **未声明**。macOS `app/macos/Runner/Info.plist:38-75` 与 iOS `app/ios/Runner/Info.plist:63-106` 已声明 UTI/文档类型 | **07** | Linux 打包产物含 `.desktop` + `MimeType`，Windows 有注册脚本/安装器声明；做不到就在文档显式 cannotDo |
| **S2** mobile cache → `systemTemp` | `app/lib/core/app_paths.dart:41,46`；`app/lib/core/nonapp_cache.dart:38,43`（iOS/Android → `Directory.systemTemp`） | 移动端缓存落系统临时目录：**系统可清，重开需重导入**（计划文档 `:150` 已登记） | **07** | 移动端杀进程/清缓存后重开行为有明确提示（或迁到应用支持目录） |
| **S2** show-in-folder | `app/lib/core/api_shelf.dart:33-55`（`revealInFolder` + `revealSupported`：macOS `open -R`、Windows `explorer /select`、Linux `xdg-open`）；消费面 `app/lib/widgets/video_player_surface.dart:121-124,182-184` | 现状是**按平台能力隐藏**（移动端不显示入口），不是运行时探测；Windows/Linux 的 `Process.run` 分支**未真机验证** | **01**（能力门）+ **06/07/08**（各消费面） | `revealSupported` 纳入 CapabilityAvailability；三平台真机各点一次；移动端空态/隐藏有测试 |
| **S4** PiP 几何持久化 | `app/lib/widgets/shell_host.dart:53-56`（`_pipOpen/_pipMax/_pipRect` 全在 State）、`:160-206`（`_clampPipRect` 统一几何） | 分栏比例、折叠态、浮窗几何**都不持久化**，重启回默认（计划文档 `:161`） | **12** | 重启后比例/位置恢复 + `test/pip_layout_test.dart`、`test/pip_gesture_test.dart` 全绿 |
| **S3** Android | `AndroidManifest.xml:41-66`、`MainActivity.kt`、构建链（本文件 §2） | 见 §2：minSdk 已修到 28；剩 1 个 Kotlin 编译错误 + 无设备 | **00**（判定）+ **07**（修 `MainActivity.kt:63`） | `scripts/wf/android_build.sh` 退出码 0（构建+安装+启动）；否则 Android 只保留远程/PLAN |

## 2. Android 当前的确切阻断（批次 00 实测）

1. **已修（批次 00 文件内）**：`app/android/app/build.gradle.kts` 的
   `minSdk` 从 `flutter.minSdkVersion`（Flutter 3.50 默认 24，
   `.flutter_sdk/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:26`）
   固定为 `28`。依据：`mediapipe_retrieval-0.3.0/hook/build.dart` →
   `mediapipe_core-0.3.0/lib/src/native_assets/family_runtimes.dart:335-338`
   直接抛「needs Android 9 (API 28); this app targets API 24」。
2. **未修（不在批次 00 文件清单，交 07）**：
   `app/android/app/src/main/kotlin/com/example/nondesign/MainActivity.kt:63`
   ```kotlin
   val uri: Uri? = when (intent.action) { ... } ?: return   // 第 58 行
   val path = materialize(uri) ?: return                     // 第 63 行 ← 编译错误
   ```
   显式标注 `Uri?` 后编译器不做非空收窄，`materialize(uri: Uri)` 报
   `Argument type mismatch: actual type is 'Uri?', but 'Uri' was expected`。
   修法：声明改为 `val uri: Uri = when (...) ?: return`（一行）。
   证据与探针结果见 `docs/migration-baseline.md` §5。
3. **环境缺口**：`adb devices` 为空；SDK 无 `emulator` 二进制、无
   `cmdline-tools`（`flutter doctor` 的 Android toolchain 为 `[!]`）。
   即使构建转绿，真机安装/启动仍需补设备或 AVD。

## 3. 不在本清单但相邻的项（避免重复认领）

- `chatStreamHome` 作为桌面主面开关、`view=='chat'` 作为桌面整块路由：
  `app/lib/main.dart:100,152-155`；由**批次 12**（main/shell_host 属主）改造为
  Workspace/Welcome + 右侧 rail，并按四档断点拆分 `ChatWorkspaceHost`
  （`app/lib/widgets/shell_host.dart:27`）——与 S4 的 PiP 几何持久化同属 12。
- `server/`、`.venv/`、`server/**/*.py` 的清退与 `scripts/wf/test*.py` 的 Dart
  重写：**批次 05+**（去 Python 线），不在 07 的 nonapp 残留范围内。
- 用户可见文案的全局术语替换（服务器/Python/wasm/…）：批次 07 只负责
  hotapp/nonapp/portfolio 面；其余面按总架构的 12/13/15 归属推进。
