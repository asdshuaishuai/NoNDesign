# NaN 文档总纲（唯一索引）

> 本文件是 NaN 仓库的**文档地图 + 决策台账 + 状态口径**。
> 执行手册是根目录 [AGENTS.md](../AGENTS.md)——改代码前先读它；本文负责回答
> 「有哪些文档、哪些已实施、哪些只是方案、某个裁决记在哪里」。
>
> 维护规则：**新增/改名/状态变化必须同步本索引**；文档之间不复制事实，
> 只做链接（move, not copy）。每个文档头部必须写状态行（格式见 §4）。
>
> **方向以 [vision.md](vision.md) 为主**；`docs/research/` 下的调研只作制作参考，
> 不反过来定义方向。

## 1. 文档分层

### 1.0 愿景（方向与取舍的唯一事实源）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [vision.md](vision.md) | 生效（2026-11-20） | **代码创造世界**：四个工作台是同一底座的四视图、七条原则、反愿景、成功判据、决策五问 |

### 1.1 执行手册

| 文档 | 说明 |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | 架构边界、产品裁决、常用命令、测试门禁、已知限制——**改代码前必读** |

### 1.2 产品与设计裁决（长期有效）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [copy-glossary.md](copy-glossary.md) | 生效中 | 用户可见文案的唯一术语表（内部词禁令、错误码人话映射） |
| [design-system.md](design-system.md) | 生效中 | 视觉与交互原则（配色、层级、动效、组件语言） |
| [plan-plugins.md](plan-plugins.md) | 定稿（按轨推进） | 插件轨道边界：Figma / 3D / 视频 = 客户端能力；RSI 质量环 = design 内置 |

### 1.3 已实施契约（描述现状，改动需同步测试）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [hotapp-from-prototype.md](hotapp-from-prototype.md) | 已实施（2026-11-18；**2026-11-20 方案将验证式热应用移入设计项目，未施工**） | 原型 → 可验证热应用的确定性覆盖检查 |
| [remote-desktop-rpc.md](remote-desktop-rpc.md) | 已实施（批次 10） | 「连接桌面」RPC 宿主：token、loopback、方法表 |
| [three-live-sandbox.md](three-live-sandbox.md) | 已实施（three-live 1.4.0，2026-11-19） | 3D 沙箱执行面、CSP 边界、双执行路径 |
| [video-clip-contract.md](video-clip-contract.md) | v1 生效（**引擎短片/Phaser 为规划的第三渲染面**） | 动效合成 HTML/CSS/JS 短片契约 |
| [manual-video-acceptance.md](manual-video-acceptance.md) | 生效中 | 视频工作台人工验收清单（代码动画裁决） |
| [context-cache.md](context-cache.md) | 生效中 | Agent 上下文与缓存策略（Dart 进程内） |
| [chat-live-preview.md](chat-live-preview.md) | 已实施（2026-11-19） | 聊天流内嵌工作区实况卡 |
| [wasm-run-vendoring.md](wasm-run-vendoring.md) | 现状（**退役方向已定，见跨平台方案 §2**） | wasm_run vendoring、离线构建、平台库校验 |
| [plan-chat-stream-shell.md](plan-chat-stream-shell.md) | 已实施（2026-11-17） | Chat Stream 主体 + 艺术架 + 画中画工作区 |
| [plan-dart-agent-migration.md](plan-dart-agent-migration.md) | 已实施（2026-11-18） | 去 Python：Dart Agent 循环迁移 |
| [plan-a2ui-web-spike.md](plan-a2ui-web-spike.md) | spike 完成（未接产品） | 官方 A2UI Web 渲染器可行性 |
| [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) | **已落地（批次 A+B1，2026-11-20）**；B2–B4 待真机/退役 | WebView 统一 `webview_all`；引擎 classic wasm + JS 宿主跑进离屏 WebView；wasm_run 仅兜底；flutter_scene 不采用 |

### 1.4 方案线（状态见各行；标「未施工」的不得当作现状）

| 文档 | 状态 | 覆盖 |
| --- | --- | --- |
| [plan-creative-workbench.md](plan-creative-workbench.md) | **方案定稿；批次 0/1/1b/2/3 已落地，批次 4 仅契约面（2026-11-24 工作树）** | 全局交互（右 chat + 执行/结果双面）、设计验证式原型绑定、3D 建模 + 3dcodeverse harness、视频导演台/剧本/三风格 + `toon_3d` 候选/TTS/配乐联动、强绑定强规范框架、施工批次 0–8 |
| [plan-next-iterations.md](plan-next-iterations.md) | **方案 v3（2026-11-24；P2 数据契约/编译/存储/预览 + 工具面（含抓帧）+ 真 three 渲染已落地）** | 收窄到视频双轨：M0 收口 → D 设计阶段（双轨 ADR/3D 视频 three-live 引擎设计/数据契约/导演台最小面）→ P1 three-live 3D 视频 POC → P2 3D 视频最小纵切；P3 常规视频只回归；音乐/VFX/TTS/视口/GLB/judge 移入 backlog；raea 嵌入已关闭（只参考） |
| [plan-workbench-ui.md](plan-workbench-ui.md) | **已落地（2026-11-24）：UI-0–UI-4，四工作台内容区独立布局；能力批次另列** | 四工作台内容区交互姿态/布局独立适配：共享外层壳不变；设计（画布专注+选区浮条）/ 3D（大纲+检查器+工具条）/ 视频（导演台+时间线+运输条）/ 音乐（项目+轨道+只读谱面+检查器+运输条）；热应用暂不改动 |
| [design/video-tracks-adr.md](design/video-tracks-adr.md) | 已落地（D1，2026-11-25 冻结；双轨并存：常规视频 v1 + 3D 视频独立项目） | 视频双轨（常规视频 / 3D 视频）边界、事实源、执行面、共享/隔离 |
| [design/video3d-execution.md](design/video3d-execution.md) | 已落地（D2，2026-11-25；2026-11-27 补真 three/WebGL 渲染面 + 帧证据，真机 `renderer=webgl_three_r160`；无 WebGL 时如实降级） | 3D 视频 three-live 执行面：场景合成/镜头时间/确定性/帧证据/性能 |
| [design/video3d-contract.md](design/video3d-contract.md) | 已落地（D3，2026-11-25；契约/校验/编译/存储/检查器；agent 工具面 `video3d_list/status/create/render_frames` 于 2026-11-27 补齐） | `scene3d.json` / `screenplay3d.json` v1 数据契约与校验 |
| [skills/creative-workbench/SKILL.md](skills/creative-workbench/SKILL.md) | **部分接线（2026-11-27 核查）：硬纪律已注入 run，完整流程未接线** | 统一创作 skill：intake → direction → structure → build → check → blind judge → refine → deliver；spec/plan/src/artifacts/judge 标准工作区；视频/3D/设计共用 |
| [plan-music-module.md](plan-music-module.md) | **方案定稿，未施工** | 音乐（编曲）模块：score.json、五线谱编辑器、Web Audio 编译播放、music_* 工具面 |
| [creative-refactor-decisions.md](creative-refactor-decisions.md) | **R0 契约核心已落地；设计 R1、3D R3 契约面已实施（2026-11-24 工作树），视频/音乐未施工** | R0 决策冻结：轮次版本化、blind judge 通道、Phaser 版本、`ink_line` 首版、TTS 随包策略、`scene.json` 双 authoring、评分默认参数；**Genkit 迁移冲突（2026-11-23 同日裁决：保留 genkit、移除 ai_sdk，见 §2 台账）** |
| [design-contract.md](design-contract.md) | **已实施（R1 设计模块，2026-11-24）** | 设计模块契约：验证原型绑定项目本身（`.ddp` 内 `prototype/`）、覆盖验证规则、`design_verify_prototype` 收口、热应用列表迁移过滤、只借 intake/judge |
| [three-contract.md](three-contract.md) | **R3 契约面 + 检查器属性编辑 + 视口预设 + 盲评已落地（2026-11-24/25/26；gizmo/GLB/多视角待后续）** | 3D 模块契约：三轨 + 双 authoring、工作区、plan schema、确定性门阈值、盲评、12 个 `three_*` 工具（已实现）、GLB/许可/迁移 |
| [video-screenplay-contract.md](video-screenplay-contract.md) | **部分落地（R0 契约 + allowlist 硬门 + Phaser 4 播放页，2026-11-28）；VFX 像素渲染/项目存储/工具未施工** | 视频模块契约：`screenplay.json` 唯一事实源、30fps 确定性、TimingCompiler、cutout rig/clip、Phaser 锁版本、三风格、pixelfx 子集、TTS、桥 v2、导出仍屏蔽、v1 兼容 |
| [music-contract.md](music-contract.md) | **R1 契约核心 + 编辑闭环 + 播放页编译产物已落地（2026-11-24/25；播放 UI/music_* 工具/五线谱编辑器未施工）** | 音乐模块契约：`score.json` v1、整数 tick（ppq 3840）、`verifyScore`、Web Audio 播放页、Bravura/SIL OFL、`music_*` 工具（拟实现）、存储与验收 |
| [plan-flutter-3.50-adoption.md](plan-flutter-3.50-adoption.md) | backlog（待排期） | Flutter 3.50 采纳清单 |

### 1.5 历史快照 / 审查（只读，不作为待办）

| 文档 | 性质 |
| --- | --- |
| [funct-chain-review-2026-11-18.md](funct-chain-review-2026-11-18.md) | 功能链路完整性审查（基线 9865ac3，只审不改） |
| [migration-baseline.md](migration-baseline.md) | 迁移批次 00 基线（门禁数字快照） |
| [round7-residuals.md](round7-residuals.md) | 第七轮残留清单（历史基线） |
| [pending-ui-fixes.md](pending-ui-fixes.md) | UI 修复台账（已全部修复，仅留档） |

### 1.6 运维 / 发布

| 文档 | 内容 |
| --- | --- |
| [release-installers.md](release-installers.md) | 安装包来源、本地复现、签名与限制 |
| [release-notes.md](release-notes.md) | Release 页面文案模板（`__VERSION__` 占位） |

### 1.7 专题研究（可施工工艺）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [research/music-arrangement-howto.md](research/music-arrangement-howto.md) | 调研结论（供施工） | 编曲：score.json 时间模型、CustomPainter 五线谱、SMuFL/Bravura、Web Audio 调度与六音色配方、模板+DP+规则编曲、校验与 A/B、许可证 |
| [research/video-animation-howto.md](research/video-animation-howto.md) | 调研结论（供施工） | 视频动画/沙雕短剧：工艺与节奏量化、screenplay/rig/clip 数据模型、cutout 木偶、30fps 确定性运行时、离线 TTS（sherpa-onnx；OS 音色仅草稿）、口型/音效、导出与验收 |
| [research/tts-offline-appendix.md](research/tts-offline-appendix.md) | 原始调研全文 | 离线 TTS 的平台细节、模型/许可证对照、时间对齐、viseme、音效与配乐联动（视频文档 §5 的出处） |
| [research/openmotion-hyperframes.md](research/openmotion-hyperframes.md) | 调研结论（**只参考，不引入**） | OpenMotion（nexu-io，Apache-2.0）与 HyperFrames（Apache-2.0）：HTML-as-video、Motion.md、Agent+Studio 同源工程、版本/导出/MCP 纪律；只借规范，不做依赖/内置/套壳/导出适配器；3D 栈例外 |
| [research/line-art-animation.md](research/line-art-animation.md) | 调研结论（**只参考，不引入**） | `JDhruv14/line-art-animation`（MIT，TypeScript）：细抖墨线 + 暖纸 + 无脸小人 + 开放双笔触四肢 + 步态求解 + 昼夜反转 + 帧条验收；我们新增 `ink_line` 风格包，只借规则/参数/验收，不依赖其 TS/SVG 库 |
| [research/awesome-opus5-5-videos.md](research/awesome-opus5-5-videos.md) | 调研结论（**只参考，不引入**） | 703 条 Opus 5.5 视频 prompt 的结构/分类/技术栈统计；六段 prompt（inputs/direction/structure/build/gotchas/start）、seek(t) 确定性、beat grid、帧证据；抽象进 `creative-workbench` skill，不复制作品/服务 |
| [research/3dcodeverse.md](research/3dcodeverse.md) | 调研结论（**3D 线直接引入**） | 3DCodeVerse 论文/harness：代码即真相、四轨七运行时、plan → check → blind judge → refine、contract/connectivity/placement/shader 门、cap 规则；附录 A 量化 threejs.cc 1,018 案例的 13 类分布/特征词/五槽 prompt 模型；Python/Blender 运行时不入产品 |
| [research/pixelfx.md](research/pixelfx.md) | 调研结论（**特效子集直接引入**） | `patch-gg/pixelfx`（MIT，v0.3.1，244 effects）：color+light 双缓冲、seeded RNG、纯/模拟 effect、sprite sheet、质量 bar；只引入火焰/冰霜/风/爆炸等特效，**不引入人物/stock actor/moves** |
| [research/claude-animated-shorts.md](research/claude-animated-shorts.md) | 调研结论（**只参考，不引入**） | `mromidev/claude-animated-shorts`（MIT，TypeScript）：55–70s 竖屏动画短剧；8 段脚本、词级时间、镜头表、2D billboard 角色 + three.js 手绘世界、墨线/景深/滑翔相机、合成声音、逐帧 QA；只借工艺/look 数值，不引入 Remotion/React/Node，`toon_3d` 候选风格 |
| [research/raea.md](research/raea.md) | 调研结论（**只参考，不引入；2026-11-24 用户最终裁决**） | `shinyobjectz/raea`（FSL-1.1-ALv2，Rust + Bevy 0.20 + React/TS）：3D/视频/动效/游戏与短剧工艺；230 crate 完整应用、私有 SDK、非可嵌入库；*Competing Use* 与形态均不适合引入。**用户复核后撤回嵌入方向，只借鉴 composition/词级时间/check/story 契约与工艺**；3D 视频执行面仍用现有 three-live，常规视频保持 v1 |
| [research/material-painter.md](research/material-painter.md) | 调研结论（**GPL 阻塞，参考 / 可选外部工作站**） | `alla2001/material-painter`（GPL-3.0-or-later，Rust + wgpu）：8 通道 PBR 绘制、烘焙、节点图、WGSL、UDIM、引擎导出预设；GUI-only 无 lib，不能嵌入；v1 自建 PBR 材质层，MCP 外部工作站为未裁决候选 |

## 2. 决策台账（按时间倒序）

| 日期 | 裁决 | 状态 | 事实源 |
| --- | --- | --- | --- |
| 2026-11-28 | **引擎短片预览面落地（可挂载）**：`VideoShortPreviewSurface`（控制器 + 真 WebView 舞台 + 播放/暂停/停止/整数帧拖动 + 时钟 + 错误面折叠技术详情/重试），控制器把 Phaser/pixelfx 内联成自包含页、走 `NONSHORT` 桥与 `NONSHORT_PLAYER` 命令面，渲染器/VFX 面如实展示；守卫锁定「WebView 宿主只用 ClipRRect」；**挂进视频工作台四栏目（项目列表/打开/栏目切换）仍待单独批次** | **已实施（2026-11-28，单测+守卫）** | `app/lib/widgets/video_short_preview_surface.dart` · `app/test/video_short_preview_surface_test.dart` · `app/test/creative_stack_guard_test.dart` |
| 2026-11-28 | **引擎短片项目库 + 工具面落地**：`VideoShortProjectStore`（`portfolio/video_short/<name>/screenplay.json` 单一事实源，先校验后落盘、拒绝同名覆盖、坏项目隔离、原子写）+ 工具 `video_short_list/status/create`（`video_` 前缀收窄、`video_short_*` 失败码全覆盖、不进产物认领）；预览面 UI 与抓帧工具未施工 | **已实施（2026-11-28，工作树+测试）** | `app/lib/core/video/video_short_project.dart` · `app/test/video_short_project_test.dart` · `app/test/video_short_tools_test.dart` · `app/lib/core/dart_agent.dart` |
| 2026-11-28 | **常规视频「剧本」契约 + VFX allowlist 硬门 + Phaser 4 引擎短片播放页落地**：新增 `app/lib/core/video/video_screenplay.dart`（`nan.screenplay/1` 解析/硬门/整数帧编译，未知字段保留、失败给 JSON Pointer；**VFX cue 必须命中 allowlist**，未知 id 编译期拒绝；预览器 `VideoScreenplayVerification` 与 3D 视频同形）与 `video_short_player.dart`（自包含单文件播放页：CSP 关网、Phaser 4.2.1 原文内联、30fps 整数帧时钟、`NONSHORT_PLAYER` 命令面 + `NONSHORT` 桥 ready/frame/ended/error）；真机 WebKitGTK 实测 `phaser=4.2.1`、seekFrame(30) 同步、画布 57,600 像素非空。**未施工**：VFX 像素级渲染接线、`screenplay.json` 项目存储/工具、风格包 | **部分已实施（2026-11-28，真机验证）** | `app/lib/core/video/` · `app/test/video_screenplay_test.dart` · `app/test/video_short_player_test.dart` · `app/integration_test/webview_pages_test.dart` · [video-screenplay-contract.md](video-screenplay-contract.md) |
| 2026-11-28 | **3D 引入 Babylon.js 作为「共同托底」**（用户裁决）：`@babylonjs/core` **9.38.0** 的 tree-shaken 最小子集（Engine/Scene/FreeCamera/MeshBuilder 四种几何/StandardMaterial/三种灯光），`third_party/babylon_web` 用 esbuild 0.28.2 打包成 `app/assets/babylon/babylon.min.js`（1,648,767 B + `build-manifest.json` 锁 sha256/字节 + Apache-2.0 许可）；3D 视频预览渲染面顺序固定 **three → Babylon → Canvas2D**，`ready.renderer` 如实回传；两档真渲染面都缺则显性失败。**不引完整 Babylon UMD（~8.9MB）、不引其物理/PBR/后处理/GLTF** | **已实施（2026-11-28，真机验证）** | AGENTS.md · [design/video3d-execution.md](design/video3d-execution.md) · `app/lib/core/video3d/video3d_player.dart` · `app/assets/babylon/` · `third_party/babylon_web/` |
| 2026-11-28 | **Phaser 引擎选型升级为 4.x**（用户裁决）：原 2026-11-20 裁决为 Phaser 3；按版本研究（Phaser 4.2.1 为当前主线，v3 最后版本 3.90）升级为 **Phaser 4.x vendored**。引擎短片仍属未施工批次（常规视频保持 v1 两渲染面），实现时按 4.x 锁版本 + manifest sha256 | **已裁决 + 运行时已入库（2026-11-28；播放页/解释器未施工）** | [plan-creative-workbench.md](plan-creative-workbench.md) §5.0 · [video-screenplay-contract.md](video-screenplay-contract.md) · `app/assets/phaser/` |
| 2026-11-26 | **主题切换为 Aqua（浅色=Aqua，不新增第三主题）**：细条纹窗口底 + 糖果凝胶主按钮（水蓝渐变+上半球高光+内发光，非毛玻璃）+ 口香糖窗口控件 + 深软阴影；凝胶白字 ≥4.5:1；焦点环可见；呼吸光晕在减少动效下静止。实现集中在 `app/lib/widgets/aqua.dart` 与 `NonPalette.light`；新增 `NonType`/`NonSpace`/`NonRadius` 令牌层 + 裸 fontSize 棘轮门 | **已实施（2026-11-26 基础层）** | `app/lib/widgets/aqua.dart` · `app/lib/core/theme.dart` · `app/test/aqua_theme_test.dart` · `app/test/design_tokens_test.dart` |
| 2026-11-26 | **音乐工作台真机点击实测（Linux/WebKitGTK 真实客户端）**：用手动鼠标事件验证五线谱↔钢琴卷帘切换（内容区 49.4% 像素变化）与播放键（运输条 0.93% 变化）；运行中诊断确认 verified=true、播放计划 16 events/61440 ticks；证据含前后截图 | **已实测（2026-11-26，Linux 真机）** | [docs/smoke/music-real-click-2026-11-26/](smoke/music-real-click-2026-11-26/) |
| 2026-11-26 | **WebView 真机事故修复**：Linux WebKitGTK 实跑发现 `Container(decoration+clipBehavior)` 生成的 `ClipPath` 无法映射到原生 WebView Overlay，导致 WebView 被隐藏（音频在跑、画面空白）；四处 WebView 宿主（音乐播放面/3D 视频预览面/动效合成面/a2ui web 卡）统一改为 `ClipRRect`；复跑集成冒烟后警告消失、5 个页面/产品面测试全绿 | **已实施（2026-11-26，Linux 实跑验证）** | `app/lib/widgets/music_playback_surface.dart` · `video3d_preview_surface.dart` · `video_clip_surface.dart` · `a2ui_web_card.dart` · AGENTS.md 已知限制 |
| 2026-11-26 | **WebView 真机化（Linux WebKitGTK 实跑）**：新增 `integration_test/webview_pages_test.dart` + `scripts/wf/run_webview_smoke.sh`（容器内自动 unshare + 宿主库 bind mount）；实跑通过音乐播放页（就绪/音频时钟 1.5s 推进/beat 桥）、3D 视频预览页（150 帧 + seekFrame + 时钟推进）、3D 视口控制（`__non3d_view`=true、沙箱面 `__non3d_grid` 回 `supported:false` 回执）；Windows WebView2 / iOS / Android 真机仍待复验 | **已实施（2026-11-26，Linux 实跑通过）** | `app/integration_test/webview_pages_test.dart` · `scripts/wf/run_webview_smoke.sh` · AGENTS.md 已知限制 |
| 2026-11-26 | **能力批次续（音乐五线谱点击插入、3D 视口控件、3D 视频新建/作品集、设计面板手势）**：音乐 `staffHitTest` + `appendNoteAt`：五线谱点击→插入四分音符（源→save→重读→播放重建，busy 闸串行）；3D `preview.html` 新增 `__non3d_view`/`__non3d_grid`（legacy 网格独立场景不污染测量；沙箱无 grid 时如实回复）+`ThreeViewportControls` 预置视角/网格/重置浮层；3D 视频新建项目/作品集扫描/顶栏分区；设计面 8px 边界双击折叠/恢复左右栏；音乐 `music_staff_view` 只读五线谱与确定性排版；**播放真机 smoke、3D 视口 gizmo 拖拽、3D 视频真机渲染未施工** | **已实施（2026-11-26，已推送）** | [music-contract.md](music-contract.md) · [three-contract.md](three-contract.md) · [design/](design/) · `app/lib/widgets/music_staff_view.dart` · `app/lib/widgets/three_viewport_controls.dart` |
| 2026-11-24 | **音乐模块 R1 契约核心 + 只读工作台落地**：`score.json` v1 解析（未知字段保留）+ `verifyMusicScore` 硬门 + 整数 tick 编译器（ppq=3840，三/五连音、字节确定性）+ `MusicProjectStore`（portfolio/music 扫描/读写/原子落盘）；`plugin:music` + `MusicWorkspace` 只读钢琴卷帘/检查器/运输条；编辑器、Web Audio 播放页、`music_*` 工具与项目跟随**未施工** | **已实施（2026-11-24，工作树）** | [music-contract.md](music-contract.md) · `app/lib/core/music/` |
| 2026-11-24 | **raea 不引入（用户最终裁决）**：复核许可（FSL-1.1-ALv2 的 *Competing Use*）与形态（230 crate 完整应用、无公开库 ABI）后**撤回嵌入方向，只借鉴**；视频仍拆常规视频（保持 v1 表面）与 3D 视频（执行面用现有 three-live），raea 只提供 composition/词级时间/`check`/story 契约与工艺参考，**不 vendor、不嵌入、不引 React/Bevy/JS 运行时** | **已裁决（只参考，不引入）** | [research/raea.md](research/raea.md) · [plan-next-iterations.md](plan-next-iterations.md) |
| 2026-11-24 | **Material Painter 不嵌入（GPL 阻塞）**：能力面覆盖全领域 3D 材质（绘制/烘焙/节点图/导出预设），但 GPL-3.0-or-later + 仅 GUI 二进制、无 `[lib]`；不 vendor、不随包分发。v1 自建 PBR 材质层；可选外部 MCP 工作站是**未裁决**的外部工具例外候选 | 调研结论（GPL 阻塞） | research/material-painter.md |
| 2026-11-24 | **动画短剧候选风格 `toon_3d`（2D 角色 + 3D 世界）**：参考 `mromidev/claude-animated-shorts` 的 8 段脚本/词级时间/镜头表/look 数值/QA；**不引入 Remotion/React/Node/Chromium**，不复制参考帧/角色/脚本/镜头；执行面用 three-live。候选待裁决与 spike | 调研结论（候选，待裁决） | research/claude-animated-shorts.md · skills/creative-workbench/references/story-short.md |
| 2026-11-24 | **3D 工作台 R3 基础批（v2 工作区/迁移/plan 校验/确定性门/测量/构建）**：spec/plan/src|scene/artifacts/judge 布局；旧项目只增不删迁移；`three_workspace_migrate` / `three_plan_validate` / `three_measure` / `three_build` / `three_check`；对象门纯函数 + caps/fix hints；scene.json 确定性编译；3D 双面阶段线/结果卡 | **已实施（2026-11-24，工作树；视口/GLB/多视角待后续）** | [three-contract.md](three-contract.md) · [creative-refactor-decisions.md](creative-refactor-decisions.md) |
| 2026-11-24 | **设计模块 R1 落地 + agent 流补齐**：项目内验证原型（`.ddp` docs `prototype` 段，确定性构建/覆盖验证/预览）→ `design_verify_prototype` 工具收口（`hotapp_from_prototype` 退役）、热应用列表过滤旧 prototype demo、双面进度线/产物卡接入设计画布；agent 侧 workspace 工具面按模块收窄、统一创作 skill 注入、盲评通道 `creative_judge`（fresh context + 图证据 + 显性降级） | **已实施（2026-11-24，工作树）** | [design-contract.md](design-contract.md) · [AGENTS.md](../AGENTS.md) Agent 层约定 · [creative-refactor-decisions.md](creative-refactor-decisions.md) §6 |
| 2026-11-23 | **LLM 层迁移到 Genkit（用户裁决）**：Dart agent 循环改用 `genkit` + `genkit_openai` + `schemantic`，**移除 `ai_sdk_dart` / `ai_sdk_openai`**，删除 `agent_model_middleware.dart`（`StreamToolNameGuard` 退场）；错误面改为 `GenkitException` / `finishReason`，`llm_no_such_tool` 的 Available tools 重试保留，近名改写随 ai_sdk 方言退场（StepFun 空名方言待真实端点抓包复核） | **已实施（2026-11-23，工作树）** | AGENTS.md Agent 层约定 · `app/lib/core/dart_agent.dart` · `app/pubspec.yaml` · [plan-dart-agent-migration.md](plan-dart-agent-migration.md) · [plan-flutter-3.50-adoption.md](plan-flutter-3.50-adoption.md) §2 修订 |
| 2026-11-23 | **创意工作台大重构 R0：五份契约文档冻结**（四份模块契约 design / three / video-screenplay / music + 决策台账）；契约测试模板口径；**Genkit 迁移冲突（同日已裁决：保留并完成 genkit 迁移、移除 ai_sdk；AGENTS/plan-flutter 已回填，见 §2 上一行）** | R0（2026-11-23）契约核心已落地；设计模块 R1、3D R3 基础批已实施（2026-11-24，工作树） | [creative-refactor-decisions.md](creative-refactor-decisions.md) · [design-contract.md](design-contract.md) · [three-contract.md](three-contract.md) · [video-screenplay-contract.md](video-screenplay-contract.md) · [music-contract.md](music-contract.md) |
| 2026-11-22 | **3D 直接引入 threejs-live + 3dcodeverse**：采用 3dcodeverse 的 skill/harness 契约（Apache-2.0）与 three-live 执行面；双 authoring（`scene.json` / `src/*.js`）；Python/Blender/CadQuery/URDF 运行时不入产品，检查器用 Dart/JS 等价实现 | 方案定稿（未施工） | plan-creative-workbench §4 · research/3dcodeverse.md |
| 2026-11-22 | **视频直接引入 pixelfx 特效子集**：只取火焰/冰霜/风/爆炸/闪电等**特效**，**不含人物/角色**；`actor`/`rig`/`poses`/`act`/`moves`/on-body 特效不引入；角色仍用我们自己的 rig | 方案定稿（未施工） | plan-creative-workbench §5.3/§5.6 · research/pixelfx.md |
| 2026-11-22 | **统一创作 skill `creative-workbench`**：intake/direction/structure/build/check/blind-judge/refine/deliver 标准化；`awesome-opus5-5-videos` 只借六段 prompt 结构与质量规则，不引入作品/服务 | 方案定稿（未接线） | skills/creative-workbench/SKILL.md · research/awesome-opus5-5-videos.md |
| 2026-11-22 | **视频新增第三种风格 `ink_line`（墨线手绘）**：参考 `JDhruv14/line-art-animation` 的线稿/步态/昼夜规则，**不引入其 TypeScript/SVG 运行时**；`silly_skit` / `line_toon` 保留，Phaser 3 与 3D 例外不变 | 方案定稿（风格包） | plan-creative-workbench §5.3 · research/line-art-animation.md |
| 2026-11-21 | **外部创作工具只参考、不引入**：OpenMotion / HyperFrames 及同类第三方创作产品不做依赖、不内置进程、不套壳、不设导出适配器；只借规范/协议/交互。**3D 栈（three.js / three-live）例外**；视频工作台 Phaser 3 裁决不变（2026-11-22 增补例外：3D 线 3dcodeverse + 视频 pixelfx 特效子集，见上） | **生效（用户裁决）** | AGENTS.md · research/openmotion-hyperframes.md |
| 2026-11-20 | **愿景：代码创造世界**——人提出世界，Agent 写源代码，工作台让世界可进入、可修改、可验证、可带走；四个工作台是同一底座的四视图 | **生效（方向与取舍依据）** | vision.md |
| 2026-11-20 | **音乐编曲实现路线**：score.json 有理数时值 → 整数 tick（ppq 3840）；CustomPainter 纯 Dart 排版；Web Audio 自写 lookahead；模板+功能和声+DP 编曲，validator 硬门 | 调研结论（施工依据） | research/music-arrangement-howto.md |
| 2026-11-20 | **视频/沙雕动画实现路线**：cutout 木偶 + 30fps 整数帧 + reset/replay seek + 种子随机；TTS 主路径 sherpa-onnx，**OS 系统音色仅草稿**（Apple SLA 限制商业发布） | 调研结论（施工依据） | research/video-animation-howto.md |
| 2026-11-20 | 所有工作台**强绑定且强规范**（项目↔工作台、工作台↔事实源、Agent↔工具面、执行归属；每模块 schema+校验器+工具族+双面四件套） | 方案定稿 | plan-creative-workbench §1 |
| 2026-11-20 | 视频引入游戏引擎：**Phaser 3**（vendored），剧本 JSON 编译为引擎短片；Godot/Unity/PixiJS/Flame 否决 | 方案定稿 | plan-creative-workbench §5.0 |
| 2026-11-20 | 视频工作台：导演台 + `screenplay.json` 标准 + `silly_skit`/`line_toon` 双风格 + 离线 TTS + **视频→音乐配乐联动** | 方案定稿（2026-11-22 增补 `ink_line`，见上） | plan-creative-workbench §5 |
| 2026-11-20 | 设计 = 验证式原型**绑定项目本身**，不再列入热应用模块 | 方案定稿 | plan-creative-workbench §3 |
| 2026-11-20 | 3D = **建模**工作台（three.js；大纲/视口/检查器 + scene.json） | 方案定稿（2026-11-22 扩展：3dcodeverse harness + 双 authoring，见上） | plan-creative-workbench §4 |
| 2026-11-20 | 全局交互：右 chat 唯一对话面；工作台只做执行过程面 + 结果面 | 方案定稿 | plan-creative-workbench §2 |
| 2026-11-20 | 音乐为第五个独立模块（只做编曲） | 方案定稿 | plan-music-module |
| 2026-11-20 | **WebView 统一 `webview_all` 全平台**（macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView）；旧 `webview_flutter` / `webview_windows` 与 Windows 专属预览已删除 | **已实施（批次 A）**；Windows/Linux 真机复验待补 | plan-cross-platform-runtime §1 |
| 2026-11-20 | **wasm 主路径 = 引擎 classic wasm + JS 宿主跑进离屏 WebView**；wasm-gc 只作未来快路径；wasm_run 降为启动失败兜底 | **已实施（批次 B1，macOS WKWebView 实跑通过）**；B4 退役待 B2/B3 | plan-cross-platform-runtime §2 |
| 2026-11-20 | **flutter_scene 本周期不用于 3D 工作台**（pre-1.0；缺建模交互层；three.js 已够用） | 裁决（可重估：≥1.0 后） | plan-cross-platform-runtime §3 |
| 2026-11-20 | 设置新增**无限步骤**（`unlimitedSteps` 哨兵，解除 4–600 步数上限与 10 分钟总时长） | **已实施**（`1259def`） | AGENTS.md · Agent 层约定 |
| 2026-11-19 | 工作台切换 = 项目切换；手机锁竖屏、平板跟随旋转；通知中心退役 | 已实施 | AGENTS.md · 产品裁决 |
| 2026-11-18 | 视频 = **代码动画**（时间线+规范编译，逐帧 SVG）；成片导出屏蔽 | 已实施 | manual-video-acceptance.md |
| 2026-11-18 | 「设计 → 热应用」为唯一模块间联动 | **已被 2026-11-20 修订**（设计原型绑定项目 + 视频→音乐联动） | hotapp-from-prototype.md（含修订注记） |

## 3. 文档之间的依赖关系（施工顺序）

```
plan-cross-platform-runtime §1（已落地：webview_all 全平台）
        │  wasm 主路径同步切换：classic wasm + JS 宿主跑进离屏 WebView（§2）
        ├──> plan-creative-workbench §2（执行/结果双面；统一 creative-workbench skill）
        ├──> plan-creative-workbench §4（3D 建模视口 + 3dcodeverse plan/check/judge；three-live）
        ├──> plan-creative-workbench §5（视频导演台 / Phaser；`ink_line` 走 Canvas2D 笔触；pixelfx 特效子集）
        │          ├──> plan-music-module（§5.5 配乐联动依赖音乐模块）
        │          └──> 3D 视频（执行面 three-live；只借鉴 raea/story-short 契约）
        └──> wasm_run B4 退役（待 Windows/Linux/移动真机复验）
```

* 音乐模块与视频引擎互不阻塞；**视频→音乐联动（批次 7）必须等音乐模块批次 1–4 完成**。
* wasm 宿主迁移（B1–B4）不阻塞工作台 UI 批次，但会替换引擎执行面——两者不要并行改
  `EngineService` 与工作台。

## 4. 状态行规范（新文档必须遵守）

文档第一行标题后紧接引用块，写明：

```
> 状态：**已实施（日期，提交）** / **方案定稿，未施工** / **施工中（批次）** /
> **spike 完成（未接产品）** / **历史快照（只读）** / **backlog（待排期）**
```

* **已实施**的文档写「现状契约」，可以直接引用文件:行；改动必须同步测试并回填本文。
* **方案定稿**的文档写「目标态」，不得使用现在时描述未落地的行为；施工后回填
  「落地锚点」（文件:行）并把状态改为已实施。
* 历史快照只追加日期与结论，不追改细节（避免把历史改写成现状）。
* 跨文档引用用相对路径；涉及裁决冲突时以**日期更新的裁决**为准，并在旧文档头部
  加「已被 X 修订」注记（本次 hotapp-from-prototype 与 plan-music-module 已按此处理）。

## 5. 对账清单（改文档时一起检查）

1. `AGENTS.md`：产品裁决表、能力矩阵、已知限制是否与本文 §1/§2 一致。
2. `copy-glossary.md`：新增用户文案是否有人话映射（不出现内部词）。
3. 已实施契约文档：文件路径、测试名是否仍存在（`flutter test` 会暴露）。
4. 方案文档：施工批次与状态行是否一致；未施工的批次不得写成已完成。
5. 本索引：新增文档必须进 §1 对应分层，状态变化必须同步 §2。

---

最后对账：2026-11-24（与 `AGENTS.md`、`vision.md`、四份方案、已实施契约头部交叉核对；
**批次 A（webview_all 全平台）+ B1（classic wasm WebView 宿主）已落地**，macOS WKWebView
真实集成测试通过；本轮新增 `creative-workbench` skill、3dcodeverse 3D harness、pixelfx
VFX 子集、`ink_line` 风格与 `toon_3d` 动画短剧候选调研；`3dcodeverse.md` 附录 A 补
threejs.cc 1,018 案例的 3D prompt 量化；新增 `raea.md` 与 `material-painter.md` 两份候选评估——**用户 2026-11-24 最终裁决：
raea 不引入、只借鉴**（许可/形态在前，嵌入方向已撤回；3D 视频执行面仍用 three-live），
Material Painter（GPL）同样只参考；可选外部 MCP 工作站仍是未裁决候选；同时已实施创意工作台大重构 R0 契约核心、Genkit 迁移、设计模块 R1
（项目内验证原型 + 双面 + 盲评通道）与 3D R3 基础批（v2 工作区/迁移/plan 校验/确定性门/
测量/构建/摆放门 + 双面），均为**工作树未提交**；剩余 3D 视口/GLB/多视角/judge、视频与
音乐模块，以及 Windows/Linux/移动真机复验、wasm_run B4 退役、OHOS 离屏 WebView 缺口
仍是未清项；未施工批次不得当现状引用）。
