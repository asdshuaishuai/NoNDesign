# plan-dart-agent-migration.md — 干掉 Python Agent 运行时的思考与方案

> 状态：**已实施并完成退场（2026-11-18，批次 15）** · 立项 2026-11-17 · 用户方向：
> 「逐步干掉 Python 的 agent SDK——每次启动都得带一个 Python 运行时太费劲」·
> 触发材料：flutter/agent-plugins、dart-lang/skills、Genkit Dart、genUI、
> Flutter AI Toolkit、Flutter AI best-practices（均已研究，研究结论在本文；两个
> skills 仓库已镜像到 `reference/`（gitignored），精选 13 个 skills 装入
> `.agents/skills/`）。
>
> **退场结果（2026-11-18）**：`server/`、`.venv/`、`plugins/video-engine/` 的
> Python 管线和 `scripts/wf/test_*.py` 回归锚点已删除；应用启动不再 spawn 任何
> 进程、不再读端口文件、默认不监听端口。`scripts/sync_models.py` 改为纯标准库、
> 只写 `app/assets/models.json`。仍保留的 Python 只是开发期同步/黄金对照工具
> （`sync_engine.py`、`video_golden_check.py` 等），不参与运行时；只服务旧
> Python 宿主的测试与 `engine_parity.py` 已删除。下方 P0–P3 的路线记录
> 与 Python 侧对照表保留作历史背景，**不要据此重新引入服务进程**。

> **修订注记（2026-11-23 用户裁决）**：Dart agent 循环的 LLM 层已从
> `ai_sdk_dart` / `ai_sdk_openai` 迁移到 `genkit` + `genkit_openai` +
> `schemantic`（[AGENTS.md](../AGENTS.md) Agent 层约定 / `app/lib/core/dart_agent.dart`
> 为现状）。本文中「`ai_sdk_dart 3.1` 为主战武器」「ai_sdk 对应物」等表述只作
> 历史背景，不再代表现状；`StreamToolNameGuard` 已随 ai_sdk 退场。

## 0. 结论先行（TL;DR）

1. **两个 GitHub 仓库不是运行时 SDK，是开发期 Agent Skills**——教编码智能体（ZCode/Cursor 等）怎么写
   Flutter/Dart 代码的指令包。它们不直接参与「干掉 Python」，但其中有**一枚关键棋子**：
   `dart-setup-ffi-assets` + `dart-use-ffigen` 两个 skill 正是官方教的「把 C/C++ 库编译进 Dart 应用」
   的路线——这是远期把 **wasmtime 引擎宿主**搬进 Dart 的官方姿势。
2. **Genkit Dart 不是「干掉后端」，是「用 Dart 重写后端」**：官方文档明确 AI 逻辑跑在独立 Shelf 后端，
   Flutter 只是 HTTP 客户端。它能替换 *Python*，但不能消灭「服务进程」这个形态，还要引入一套新框架。
   **不建议作为核心框架引入**（详见 §3.1）。
3. **真正的主战武器已经在仓库里**：`ai_sdk_dart 3.1 + ai_sdk_openai`（pubspec 已有）+
   `mobile_agent.dart` 的 PLAN 直连实证（真机跑通 12 步工具循环）。OpenAI Agents SDK 在 Python 侧
   用的能力（function_tool / Runner.run_streamed / reasoning），ai_sdk_dart 全部有对应物
   （tool / streamText / CancellationToken）。**agent 循环层的迁移不缺 SDK，缺的是把 server/agent.py
   的工具语义与提示词搬过去。**
4. **Flutter AI Toolkit（1.0 稳定）**：聊天 UI + provider 抽象 + tool calling。我们的 Agent 面板是
   时间线不是聊天流，整体替换价值低；「自定义 provider」接口值得在引入聊天式助手时参考。可选。
5. **genUI —— 已弃用，继任者 `a2ui_flutter`；判定翻转为「采纳为第二渲染后端」**（2026-11-17
   用户裁决，详见 docs/plan-chat-stream-shell.md）：HTML 热应用与 A2UI surface 并存、按复杂度
   自适应分派（视觉动画→HTML；数据交互表单→a2ui），文件格式 v2 带 `renderer` 字段。
6. **best-practices 的核心冲突点**：官方推荐 Firebase AI Logic 管 key（key 不进客户端）；我们是
   **用户自带 key、存本机设置**（桌面单用户场景，AGENTS 已登记 keychain 增强）。保持自带 key 模型，
   把「Morgan's Law → guardrails」思想落地为：**Dart 侧 agent 循环必须继续过引擎门**，护栏不搬走。

## 1. 背景与痛点

- 桌面：`ServerLauncher`（app/lib/core/api.dart）每次启动要找到 Python 解释器、spawn
  `server/main.py`、读端口文件、看门狗；`.venv` 与 openai-agents 依赖是随仓库分发的安装负担。
- 移动：iOS/Android 无法跑 Python → 只有两层模式（LAN 连桌面 / PLAN Dart 直连降级）。
  3D/视频/热应用生成/引擎画布全在桌面。
- 本轮方向（用户原话）：agent 循环尽量 Dart 化，摆脱 Python 运行时。

## 2. 现状盘点：Python 侧到底承担什么

`server/agent.py`（783 行）基于 **openai-agents**（`from agents import Agent, Runner, function_tool,
ModelSettings`）。把「agent SDK」与「服务运行时」两层分开看：

### 2.1 Agent 循环层（本方案主目标，Dart 可替代）

| Python 侧能力 | 实现 | ai_sdk_dart 对应物 | 差距 |
| --- | --- | --- | --- |
| 工具循环 | `function_tool` ×~10（design_op 引擎门 / read_mbt / inspect / list_templates / list_components / read_docs / write_doc / write_design_spec / finish） | `tool()` + `Schema`（mobile_agent.dart 已实证） | 需把工具语义/参数校验逐个移植 |
| 流式 | `Runner.run_streamed` → SSE 事件桥（assistant_text / thinking_delta / tool_start / tool_end / doc_written / preview / done / failed） | `streamText` 的 textStream / toolCall 流 | 事件分类要自建薄层 |
| reasoning 档位 | `ModelSettings(reasoning=Reasoning(effort))` | ai_sdk_openai provider kwargs | 各家方言（thinking_extra_body 类）需自建表 |
| 三模式状态机 | PLAN（nudge 轮 + doc_not_written）/ Build / Refine | 纯 Dart 逻辑 | 直接移植（mobile_agent 已有 PLAN 骨架） |
| 多轮上下文/裁剪 | context.py（项目地图、supersede、逐模型窗口） | 纯 Dart 逻辑 | 移植 |
| 模型注册/能力门控 | models_store + /models | **已解决**：上轮 mobile-2 修复把 models.json 快照打进 app 资产（`ensureBundledRegistry`） | — |
| 中断 | 无（Python 侧靠断连） | `CancellationToken`（已在 store 用） | Dart 侧反而更干净 |

### 2.2 服务运行时层（非 agent SDK，但同属「Python 运行时」痛点）

| 职责 | 现状 | Dart 替代路径 | 难度 |
| --- | --- | --- | --- |
| MoonViz wasm 引擎宿主（session 缓存、`_in` 槽 ABI） | wasmtime（Python 包） | **Dart FFI + wasmtime C API**（wasmtime 有稳定 C API；`dart-setup-ffi-assets`/`ffigen` 官方 skills 正好教这条；MoonViz classic wasm 零 import、宿主中立，是 FFI 友好前提） | 高，但路径清晰 |
| DDP 编解码（zstd + Argon2id + XChaCha20-Poly1305） | 纯 Python 包 | Dart 侧：`cryptography`/`zstandard`(FFI)/`argon2` 系包，或同样 FFI | 中 |
| resvg / ffmpeg 渲染 | subprocess 调桌面二进制 | Dart `Process.run` 即可（桌面不变，移动端本来就不可用） | 低 |
| 热应用 SQLite 桥 / 文件 IO | Python sqlite3 / aiofiles | 桥只在「连接桌面」模式需要；文件即应用（本轮方向）本就要做到离线直载 | 低 |
| three/video 静态资产服务 | FastAPI 静态路由 | WebView 直载 / 打包资产 | 低 |

## 3. 六项资料逐一判定

### 3.1 Genkit Dart ——「用 Dart 重写后端」，不是「干掉后端」

- 形态：AI 逻辑跑在 **Shelf** 后端（Dart 目前唯一后端选项），Flutter 经 HTTP 调 flows。
- 能带来：flows/tools/多 provider 胶水、devtools 观测、`dart compile exe` 后可分发**无 Python 的
  单二进制服务**。
- 判定：**不作为核心框架引入**。理由：① 它解决的是「服务端用什么写」，而我们的第一优先是「agent
  循环进客户端」，两者正交；② 引入一套框架债，而 ai_sdk_dart 已在客户端覆盖同一能力面；③ Dart 后端
  生态仅 Shelf，成熟度存疑。**唯一值得回头看的时机**：走到 §5 P3（引擎宿主 Dart 化）时，若决定保留
  「服务进程」形态，可用 Genkit 或裸 Shelf 重写；届时再评估。

### 3.2 flutter/agent-plugins + dart-lang/skills —— 开发期弹药，已装

- 性质：Agent Skills 指令包（SKILL.md），给编码智能体用，与本应用运行时无关。
- 已装入 `.agents/skills/`（13 个精选）：widget 测试、修布局溢出、响应式、架构分层、JSON 序列化、
  集成测试（Flutter 6 个）＋单测、静态分析、运行时错误修复、mock、模式匹配、**FFI/native assets ×2**、
  mock（Dart 7 个）。
- 直接价值：后续每轮开发（含本文 P0–P3 的实施）在 ZCode 会话里自动带上这些工作流；
  `dart-setup-ffi-assets`/`dart-use-ffigen` 是 P3 引擎 FFI 的官方操作手册。

### 3.3 Flutter AI Toolkit —— 可选 UI 件

- 1.0 稳定；`LlmChatView` + provider 抽象（自定义 provider 即插）+ tool calling + 流式 + 序列化。
- 判定：**可选引入**。我们的 Agent 时间线（op 流/轨迹卡）不是聊天流，整体替换不合适；
  未来若做「NaN 助手」闲聊/答疑面板，直接用它 + 自定义 provider（指向桌面服务或直连）。

### 3.4 genUI → `a2ui_flutter` —— 采纳为第二渲染后端（2026-11-17 更新）

- **`genui` 包已弃用**（pub.dev 0.10.4 标 discontinued），官方继任者 **`a2ui_flutter` 0.3.0**
  （+ `a2ui_core` / `a2ui_agent`，Flutter 官方实验室，全平台）。
- 能力事实：基础目录自带表单级组件（TextField/CheckBox/ChoicePicker/Slider/DateTimeInput），
  DataModel 路径绑定 + `props.isValid` 校验 + 动作自动回流 agent；基础目录**无图表/动画**
  （图表需自定义 `ComponentImplementation`）；transport 无关——`outboundListener`/
  `unifiedOutbound` 可接任意 LLM 循环（含 ai_sdk_dart），`a2ui_agent` 还提供教模型 A2UI 的
  系统提示生成器与流解析。
- 判定（用户裁决）：**与 HTML 热应用并存、自适应分派，不互相替代**——HTML 管可移植与视觉
  动画，a2ui 管复杂交互组件与「agent 续写」交互；分派标准与文件格式 v2 见
  docs/plan-chat-stream-shell.md §1。

### 3.5 best-practices —— 三条采纳、一条登记差异

- 采纳①：**guardrails**——AI 必有失败率（Morgan's Law），我们的护栏是引擎门 + RSI 质量环；
  Dart 化后 agent 循环**仍必须经引擎门提交**，不允许 Dart 侧绕过门直写画布。
- 采纳②：**用户验证 AI 数据**——热应用/3D/视频产物进作品集前已有人工打开环节，保持。
- 采纳③：AI 生成 Flutter 代码用 analyzer/测试当护栏——即本轮装入的 skills。
- 差异登记：官方推 Firebase AI Logic 管 key；我们是**用户自带 key**（设置里填，存本机），
  与「key 不进客户端」官方建议相反——这是产品定位（自带 key、无云依赖），保留，keychain 增强
  维持既有登记。

## 4. 替换矩阵（Python agent SDK → Dart）

| # | Python 能力 | Dart 替代 | 阶段 |
| --- | --- | --- | --- |
| 1 | PLAN 循环（write_doc 双文档 + nudge + doc_not_written） | `mobile_agent.dart` 泛化为 `core/dart_agent.dart`（三模式共用骨架） | P0 |
| 2 | Build/Refine 循环（design_op 引擎门 + read_mbt + inspect…） | 同上 + 桌面经 HTTP 打引擎门（工具实现在客户端、op 提交在服务端） | P1 |
| 3 | 流式事件（SSE 桥 8 类事件） | `streamText` → 复用现有 TimelineEntry 渲染 | P1 |
| 4 | reasoning/thinking 方言 | 自建 Dart 方言表（以 server 现表为权威翻译） | P1 |
| 5 | 上下文裁剪/项目地图 | context.py 语义移植 | P2 |
| 6 | 模型快照/能力门控 | **已完成**（资产化快照） | ✅ |
| 7 | 中断/取消 | CancellationToken（已完成接入） | ✅ |
| 8 | 引擎宿主 | Dart FFI + wasmtime C API（skills 官方路线） | P3 |
| 9 | DDP 编解码 | Dart 包/FFI | P3 |
| 10 | resvg/ffmpeg/静态服务 | Process.run + 打包资产 | P3 |

## 5. 分阶段路线图

> **2026-11-17 用户裁决更新**：chat stream 主体 + 艺术架 + 画中画工作区已立项
> （docs/plan-chat-stream-shell.md），本路线图 **P0–P2 升格为该方案的硬前置**
> （chat stream 的 agent 就是内置 Dart 循环）；P3 维持独立立项。

- **P0（纯 Dart 双端统一入口，1 个 PR 量级）**：把 `mobile_agent.dart` 泛化成 `core/dart_agent.dart`
  ——PLAN/Refine 两模式先行（都不依赖引擎写路径）；设置页加「Agent 运行时：内置 Dart（默认移动端）/
  桌面服务」；桌面选内置 Dart 时 agent 循环也走客户端，引擎门仍走 HTTP 服务。
- **P1（Build 模式 Dart 化）——2026-11-17 主体落地**：design_op 经 HTTP 引擎门、thinking 方言表、
  与 SSE 同形的事件面（tool_start / tool_end / doc_written / preview / done / failed 等）均已在
  `core/dart_agent.dart`；本轮补齐 server 收尾桥段——**generate_page**（独立 `EngineWriteBridge`
  接口 → `/engine/generate`，成功发 `page_generated`）、**RSI 评审环**（`session_critique` 的
  `poor` 板 → `session_auto_fix` 回灌 canonical，最多 2 轮）、**空板清扫**（`_sweepIdleArtboards`：
  删 `__seed`/≤1 节点板，永不留零板）。PLAN 分歧（Dart plan 无引擎面 → 直接 return，server plan
  也执行）在代码头注释与测试组名显式登记；`server/agent.py` 仍为可选后端。**仍留后续**：逐字
  `doc_delta` 流式直播（SDK 工具参数增量是原始 JSON 分片，需自建内容提取器）与 agent 驱动的
  A2UI 卡（卡渲染/动作回流已接 `store.handleChatAction`，生成器侧产出 A2UI 消息并续跑的闭环未接）。
- **P2（上下文层移植）**：项目地图/裁剪语义进 Dart；服务端 agent 路由与 openai-agents 依赖删除
  ——**此后「带 Python 运行时」只剩服务运行时层**。
- **P3（服务运行时 Dart 化，独立立项）**：wasmtime C API + ffigen 引擎宿主 → DDP Dart 化 →
  resvg/ffmpeg Process 化 → 服务端整体退役或 `dart compile exe` 单二进制（届时若保留服务形态，
  再评估 Genkit/Shelf）。
- 明确不做：A2UI/genUI（观望）、Firebase AI Logic（自带 key 定位不变）、Genkit（除非 P3 选服务形态）。

## 6. 风险与护栏

1. **方言漂移**：各家 thinking/reasoning 参数是「线上方言」，models.dev 不覆盖——Dart 方言表必须
   以 Python 现表为权威翻译并写对照测试（删表前先对拍）。
2. **引擎门不可绕过**：Dart 循环的 design_op 仍走 `/engine/apply`（AgentGate）；任何「直接拼 mbt 提交」
   的捷径都是回归。
3. **事件契约**：前端时间线消费 8 类事件，Dart 循环必须产出同形事件（先写契约测试再实现）。
4. **PLAN 语义对齐**：以 server PLAN 为权威（doc_not_written / nudge 轮），上轮已登记 mobile-3 漂移
   ——P0 泛化时一并对齐。
5. **FFI 风险（P3）**：wasmtime C API 版本锚定、native assets 工具链要求；先 spike 再立项。

## 7. 本轮已落地（非计划项）

- `reference/agent-plugins`、`reference/dart-skills` 只读镜像（gitignored，随时可 `git pull` 更新）。
- `.agents/skills/` 装入 13 个精选 skills（Flutter 6 + Dart 7），对本仓所有后续智能体会话生效；
  更新方式：重跑两个仓库的克隆目录拷贝，或官方 `npx skills add`。
