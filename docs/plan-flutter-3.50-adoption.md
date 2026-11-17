# plan-flutter-3.50-adoption.md — 下一迭代轮次：Flutter 3.50 采纳清单

> 状态：**下一迭代（backlog，待排期）** · 2026-11-17 · 来源：Flutter 3.50 调研
> （官方 3.50 博客 / 3.50 release notes / breaking changes 索引 / Dart 3.14 公告 /
> A2UI 1.0 / MediaPipe for Flutter / Genkit Dart 1.0）。
> 生成内容改代码前必须先读 AGENTS.md 的边界与既有裁决；本文件是排期依据，不是施工令。
>
> **决策记录（2026-11-17）**：① MediaPipe for Flutter —— **采纳，只引入基础 task 能力**
> （视觉 / 文本 / 检索，见 N6）；**端侧 LLM（LiteRT-LM / Gemma）暂不考虑**（难度大，用户决策）；
> ② Genkit Dart 1.0 —— **不引入**，维持原判定（见 §2）。

## 0. 版本事实（2026-11-17 实测）

| 项 | 现状 |
| --- | --- |
| 本机 SDK | Flutter 3.50.0 stable / Dart 3.14.0（2026-11-09 发布） |
| 本仓 pubspec | `environment: sdk: ^3.14.0`——已在 3.50 线上 |
| Material 导入面 | 36 处 `package:flutter/material.dart`（`lib` 仅 30 个 dart 文件）；`material_ui` 依赖在 `pubspec.yaml` 但**代码零使用**，且钉 `^1.1.0`（最新 1.11.1） |
| Android | AGP 9.3.1 / Gradle 9.5.0（`app/android/settings.gradle.kts`、`gradle-wrapper.properties`），与 3.50 新模板一致 |
| iOS | `ios/Runner/Info.plist` 已有 `UIApplicationSceneManifest`（UIScene 迁移已完成） |
| 本地化 | 未使用 `flutter_localizations`（grep 0），本地化代理迁移可跳过 |

## 1. 下一迭代项（按优先级）

### N1（P0）material_ui / cupertino_ui 迁移 —— 约半天，1 个 PR

3.50 起 `package:flutter/material.dart`、`package:flutter/cupertino.dart` 及
`flutter_localizations` 对应代理**正式弃用**；新项目默认 `package:material_ui`。

步骤：
1. 独立分支跑 `dart fix --apply --code=migrate_design_widgets`（自动加依赖、改导入）；
2. 若 pubspec 未更新：`flutter pub add material_ui`，并把约束抬到当前 `^1.11.x`；
3. 手工核对 `AppTheme` / `ThemeData` / `ColorScheme` **类型同一性**——SDK 旧类型不能喂给
   material_ui API（这是迁移期唯一的硬错来源）；
4. 仍依赖旧导入的第三方包（a2ui_flutter / webview_flutter 等，按检出结果）用
   `MaterialUiCompatibilityBridge` 包在 `MaterialApp.builder` 里过渡；
5. 跑五门禁（compileall / analyze / flutter test 全量 / test_hotapp / test_server_routes），
   回归画布、inspector、设置、聊天流四个主面。

风险：`dart fix` 早期版本有 pubspec 更新失败的问题——失败就手动 `pub add` 后重跑。桥接器
本身标 `@Deprecated`，是过渡工具，第三方包迁移完成后要摘掉。

### N2（P1）A2UI 1.0 能力收编

本仓已钉 `a2ui_flutter 0.3.0 / a2ui_agent 0.3.0 / a2ui_core 0.7.0`——这正是 1.0 时代的
包版本线（包版本 ≠ 协议版本，0.3.0 已支持 protocol 1.0 与 0.9）。可收编的能力：

- **Express 推理格式**：`a2ui_agent` 新默认，token/延迟最多降 3×——直接缓解
  `docs/plan-chat-stream-shell.md` 风险 #2（A2UI 系统提示 3000–5000 token 吃小模型上下文）；
- **嵌套护栏**：渲染前拦截荒谬嵌套并让 agent 自我纠正——给聊天流 A2UI 卡加稳定性，无需自写兜底；
- **多 Catalog**：`MessageProcessor(catalogs: [...])` 一个 surface 可组合多个目录——`.nonapp`
  a2ui 载荷可声明「内置目录组合」；自定义 `CatalogItem` 仍是编译期 Dart 代码，§1.1 的
  「打包应用限内置目录」约束不变；
- **Client-Side Functions**（a2ui_core 0.7.0）：UI 可调用预注册的本地 Dart 函数（计算/校验/
  格式化），不必回 agent 一轮——热应用式交互的强候选，安全模型仍是白名单；
- `SurfaceModel.metadata` / `node.metadata`：可透传 trace id、样式开关。

落点只在 `app/lib/widgets/a2ui_card.dart` 封装层内，不改 store/聊天流契约。

### N3（P1）Android 构建加固（AGP 9 收尾）

- 第五轮登记的「Android 打包门禁挂起（Gradle 9.5 / AGP 9.3.1）」专项排掉；
- 3.50 要求插件用 built-in Kotlin、AGP 9 DSL——核对 webview_flutter / file_selector /
  shared_preferences 兼容性；
- **3.50 收紧了 release 构建的外部 Intent 校验**（route / `dart_entrypoint` /
  `cached_engine_id` 不可由外部 Intent 传入）——`.nonapp` 文件关联的 intent-filter 不得
  依赖传 engine 参数，文件内容一律走插件/通道读取。

### N4（P2）wasmtime FFI 宿主立项（`docs/plan-dart-agent-migration.md` P3 路线）

3.50 让这条路线从「高风险探索」降为「按官方手册施工」：FFIgen（C + Objective-C）与
JNIgen（Java/Kotlin）均 stable，支持同步调用与后台 isolate 调用，官方新增 interop 文档区。
先做 spike：wasmtime C API + `ffigen` 绑定、`_in` 槽 ABI 在 Dart 侧的最小闭环、与现有
Python 宿主的结果对拍。结论再决定是否立项。

### N5（P2）桌面多窗口 / 工作区拆窗（S4 之后可选）

官方 Desktop Windowing API 成型：`RegularWindow` → `Window`、`sizedToContent` →
`shrinkWrap`、`WindowManager` 提到 `WidgetsApp` 之外；Win32 satellite windows；macOS
content-sized window。用途：把工作区从聊天流拆成独立 OS 窗口（画中画的桌面延伸），
或「聊天窗 + 工作区窗」双窗协作。非必需，S4 落地后评估。

### N6（P1，已采纳）MediaPipe 引入（2026-11-17 用户决策）

**决策：引入 MediaPipe for Flutter，但只用基础 task 能力**（视觉 / 文本 / 检索 / 决策），
**不引入 LiteRT-LM / Gemma 端侧 LLM**。排在第六轮（S2–S4）提交之后施工——`pubspec.yaml`
当前由 `.nonapp` 施工占用、门禁在跑，不在并行期动依赖。

分阶段落地（每阶段独立可交付）：
- **M1 底座**：引入 `mediapipe_core` + `mediapipe_retrieval` + `mediapipe_vision` +
  `mediapipe_text`（钉 0.2.x）；
  新建 `app/lib/core/mediapipe_service.dart` 薄封装——模型下载/缓存（应用支持目录 `models/`，
  sha256 校验，首次下载带进度）、推理放独立 isolate（不卡 UI）、平台能力探测（Android /
  iOS / macOS Apple Silicon / Linux x64 / Windows x64）。模型**不随安装包分发**。
- **M2 首个价值切片（离线语义检索）**：Universal Embedder + Semantic Retriever 建本地索引
  （作品集 / 热应用 / 文档），艺术架与聊天流各加一个检索入口；验收 = 断网可用、零网络请求、
  索引落盘可增量更新。
- **M3 视觉能力**：InteractiveSegmenter 抠图（设计资产提取）+ ObjectDetector 截图元素识别
  （接「截图 → 原型」链路的前处理）。

风险：包仍 0.x（API 可能动，封装层隔离）；原生库对 Android 16KB page size / Impeller 的
兼容性要实测；桌面 FFI 与浏览器 Wasm 性能分层明显。任务矩阵与候选场景见 §3。

**实施记录（2026-11-17）**：M1 + M2 已落地——`mediapipe_core/retrieval/vision/text 0.3.0`
（archive 由 ^3.6.1 升到 ^4.2.0，nonapp 侧同步迁移）；`MediaPipeService`（下载/sha256/原子
落位/isolate 推理/降级）+ `EmbeddingIndex`（增量索引/余弦/子串兜底）+ 艺术架搜索框；
57 项定向测试。**构建面**：MediaPipe 无 Intel iOS 模拟器切片，Runner 三个配置已落
`"EXCLUDED_ARCHS[sdk=iphonesimulator*]" = x86_64;`（否则 `flutter build ios --simulator`
在 native assets 阶段失败）；macOS 同理在 `macos/Runner/Configs/AppInfo.xcconfig` 显式
`ARCHS = arm64` / `EXCLUDED_ARCHS = x86_64`（Flutter release/profile 默认带 Intel，
Intel Mac 宿主随 Flutter 3.50 退役）。
模型注册表只登记官方来源可核实的 Universal Embedder 模型；vision/text 模型 URL/sha256
留 TODO（未编造）。

### N7（P3）工程卫生（记录即可）

- `dart migrate` 纳入 SDK 升级流程（`--dry-run` → `--apply`，支持 prepare/bump/cleanup 分步）；
- Intel Mac 宿主进入退役通道（`flutter config --enable-macos-arm64-only` 可选）；
- SwiftPM 退出选项开始告警，CocoaPods 回退未来移除——桌面/移动构建脚本届时核对；
- 本仓无 web 产品面，Wasm allowList / `--web-content-hash` 仅记录，不实施。

## 2. Genkit Dart 1.0 判定（2026-11-17 结论）

**事实**（2026-10-08 发布 1.0，当前 1.0.2）：

- 稳定层：多 provider（Gemini / Claude / OpenAI / OpenAI 兼容 / Ollama 等）、类型化 Flow
  （`schemantic`）、流式、tool calling、`GenkitRouter`（Flow 直接注册为 HTTP 接口）、
  `defineRemoteAction` / `defineRemoteModel`（客户端调远程 flow / 请求走自有后端）、
  tool `.interrupt` 人类确认、中间件（重试 / SKILL.md 加载 / 工具批准规则）、Dotprompt、
  `genkit start` 开发 UI、`genkit_otel` OpenTelemetry。
- **实验层（`package:genkit/experimental.dart`，不在 semver 保证内）**：`defineAgent`
  多轮 agent、会话持久化、快照、agents 委托、双向层、`genkit_a2ui`（agent 直接吐交互界面）。

**判定：不引入为运行时框架，维持 `docs/plan-dart-agent-migration.md` §3.1 的结论。**
**2026-11-17 用户确认：维持本建议（Genkit 不引入）。**

理由：
1. **架构形态不匹配**：Genkit Dart 的官方路径是 Shelf 后端 + Flutter 经 HTTP 调用——它是
   「用 Dart 重写后端」，不是「消灭服务进程」。我们的内置 Dart 循环（ai_sdk_dart，客户端
   直跑、双端可用、直接过引擎门）才是「无进程」路线；换 Genkit 等于把进程重新引回来。
2. **能力面已被覆盖**：provider 抽象 / tool calling / 流式 / 类型 schema 我们已有；
   RAG、dev UI、OTel 当前不是瓶颈。
3. **我们最想要的部分恰在实验区**：多轮 agent 与会话持久化仍在 experimental，且明确可能
   在小版本改动或删除——发版应用不能押上去。

**两个值得回头的场景**（登记，不排期）：
- 若 P3（服务运行时 Dart 化）最终决定保留「服务进程」形态：Genkit Dart 1.0 是比裸 Shelf
  更完整的选择（flows + 可观测 + 多 provider）；
- 开发期 prompt 调试：`genkit start` 的 trace/dev UI 可作本地调参工具，不影响线上架构。

可借鉴的设计（不引入框架）：tool `.interrupt` 的「有副作用先停等人确认」与我们的
HumanGate / 引擎门同构；中间件式的「工具批准规则」可作为 agent 工具面的后续参考。

## 3. MediaPipe for Flutter 摘要（评估材料）

**是什么**：Google AI Edge 的官方 Flutter SDK（pub.dev publisher `google.dev`，仓库
`google/flutter-mediapipe`，Apache 2.0）。一套 Dart API 覆盖 Android、iOS、macOS（Apple
Silicon）、Linux x64、Windows x64 与 Web；桌面/移动经 Dart FFI 捆绑原生 MediaPipe 库，
浏览器加载固定版本 Wasm 运行时。当前 0.2.1（3.50 博客口径为 20 个 task，官方 Tasks 目录
现列 22 个 task 类）。

**包与任务（5 个 family 包 + `mediapipe_core`）**：

| 包 | 任务 |
| --- | --- |
| `mediapipe_vision`（11） | FaceDetector、ObjectDetector、FaceLandmarker、HandLandmarker、PoseLandmarker、HolisticLandmarker、GestureRecognizer、ImageClassifier、ImageEmbedder、ImageSegmenter、InteractiveSegmenter |
| `mediapipe_text`（5） | TextClassifier、LanguageDetector、TextEmbedder、TextProofreader、TextSummarizer |
| `mediapipe_audio`（3） | AudioClassifier、AudioTranscriber、Text-to-Speech |
| `mediapipe_retrieval`（2） | Semantic Retriever、Universal Embedder |
| `mediapipe_decision`（1） | Decision Maker |

**在 NoNDesign 的候选场景**（按价值排序）：
1. **作品集/资产/文档的离线语义搜索**：Universal/Image/Text Embedder + Semantic Retriever，
   本地 RAG，不上传用户数据；
2. **设计资产提取**：ImageSegmenter / InteractiveSegmenter 抠图，ObjectDetector 识别截图
   元素（可接「截图 → 原型/3D」链路的前处理）；
3. **离线文案与语言处理**：LanguageDetector（多语言 UI/内容分流）、TextProofreader、
   TextSummarizer（离线草稿校验）；
4. **画布/演示手势（实验性）**：GestureRecognizer / HandLandmarker 做免接触翻页或演示模式
   手势——先做可行性验证，不进主流程；
5. ~~端侧 LLM（与 task 包分开）~~：**暂不考虑**（2026-11-17 用户决策，难度大）——LiteRT-LM +
   Gemma 模型 GB 级（E2B 约 2.59GB）、Flutter 侧仍偏社区包、桌面/移动推理差异大，暂不进路线。

**约束**：包仍 0.x（API 可能动）；task 模型随包或首次下载（通常几 MB 到几十 MB）；移动端
GPU/NPU 加速可用但桌面 Web 走 Wasm，性能分层明显；引入前先做单点 spike（建议从
ImageEmbedder + Semantic Retriever 开始）。

## 4. 明确不做（本轮）

- 不因 3.50 升级 SDK——已经在 3.50.0 上；
- 不引入 Genkit Dart 作为客户端 agent 循环（理由见 §2）；
- 不为 Web 目标适配 Wasm / content hash（本仓无 web 产品面）；
- 端侧 LLM（LiteRT-LM / Gemma）暂不考虑——用户决策 2026-11-17（GB 级模型、Flutter 侧成熟度
  不足、桌面/移动推理差异大）；MediaPipe 只用基础 task 能力。

## 5. 参考

- 官方 3.50 博客：https://flutter.dev/blog/whats-new-in-flutter-3-50
- 3.50 release notes：https://docs.flutter.dev/release/release-notes/release-notes-3.50.0
- 破坏性改动索引：https://docs.flutter.dev/release/breaking-changes
- Dart 3.14：https://dart.dev/blog/announcing-dart-3-14
- material_ui：https://pub.dev/packages/material_ui
- MediaPipe Flutter 文档：https://developers.google.com/edge/mediapipe/solutions/guide
- Genkit Dart：https://genkit.dev/docs/dart/get-started/
