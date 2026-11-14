# AGENTS.md — NoNDesign

AI 原生原型设计工具的桌面客户端。**一句话 → 产品需求设计文档 → 完整可交互原型**。

**技术栈（用户决策，2026-11-13）：Flutter 3.50（macOS 主目标；linux/windows 平台壳已就位）+ Python OpenAI Agents SDK。
不要重新引入 Bun、Tauri 或任何 JS 前端运行时。**

## 架构边界（改代码前先读）

```
app/          Flutter UI + 原生 CustomPainter 画布（无 WebView、无 HTML）
server/       Python FastAPI + OpenAI Agents SDK + wasmtime 引擎宿主 + DDP
engine/       MoonViz classic wasm（纯 WASM MVP、零 import）+ components.json
```

- **唯一事实源**：一份 canonical `.mbt.md`。人类画布操作（HumanGate）与 Agent 操作
  （AgentGate）都必须经引擎校验后回写同一份文档；`.ddp` 只是它的认证加密容器。
- **Flutter 不解释视觉语义**：它只渲染引擎返回的 `artboards[].nodes[]`、发送 op、
  展示事件。不要在 Dart 里"顺手"改布局/属性——变更必须回到引擎。
- **Python 是唯一 Agent 宿主**：`server/agent.py` 拥有 Agent 循环、tools、上下文与
  会话；Flutter 只消费 SSE 事件。不要在前端复刻 LLM 协议。
- **引擎宿主只有一处**：`server/engine.py`（wasmtime）。所有 `_in` 槽协议、
  字符串读 ABI、session 缓存、epoch 超时都在这里；Flutter 不直接碰 wasm。
- **上下文分层**：静态指令 → PROJECT MAP → 设计规范/文档 → 会话记忆 + 最新 state。
  稳定前缀不要插入时间戳/随机序；变更走追加式 state 卡，不重写历史。
- **模型与端点**：`server/models.json` 是 models.dev 的 vendored 快照；`server/models_store.py`
  负责刷新。不要硬编码模型能力，能力轴以快照为准；线上方言（thinking 等）单独裁决。

## 常用命令

```bash
# Python
python3 -m venv .venv
.venv/bin/pip install -r server/requirements.txt
cd server && ../.venv/bin/python main.py --port 8799
.venv/bin/python -m compileall server

# 引擎 / 模型
.venv/bin/python scripts/sync_engine.py           # 校验/下载 wasm，真机 render 探针
.venv/bin/python scripts/sync_models.py           # 刷新 models.dev 快照

# Flutter
cd app
flutter analyze
flutter test                                      # widget + SSE 测试
flutter run -d macos                              # 自动拉起 Python 服务
flutter build macos --debug
```

服务端默认绑定 `127.0.0.1` 的临时端口，Flutter 启动时读取
`~/.nondesign/server.json` / stdout 拿到端口。`NONDESIGN_SERVER` 可指向已运行服务。

## 引擎 ABI（不要凭猜测改）

- 写方向：`in/arg/arg2` 三槽，UTF-8 分块（每块小端 4 字节 + 有效长度），调用
  `*_in()` 变体。`server/engine.py::_slot` 是唯一实现。
- 读方向：引擎返回字符串指针，布局 `[len@ptr-4][UTF-16LE@ptr]`；
  `_read_str` 是唯一实现。
- 每次调用（包括 `version_info`）都要重设 epoch deadline；ticker 线程持续推进时钟，
  闲置后不重设会立即 trap。trap 后必须丢弃 session 并重建实例。
- 会话 API 按 canonical MBT 键控；变更信封的 `mbt` 必须回写缓存。任何 trap/腐坏读
  都弃缓存。
- `list_components` 用 `engine/components.json` 快照；`list_templates` 直接问引擎。

## Agent 层约定

- `server/prompts.py`：Plan / Build / Refine 三套静态提示词 + 公共 footer。改提示词时
  守住"生成优先"、"按钮不卡文案"、"对比度硬规则"、"列表分隔线"、"flow 绑容器"这些引擎规范。
- `server/agent.py`：tools 用 `@function_tool(strict_mode=False)`；参数用普通类型，
  不要依赖 strict JSON schema（兼容网关会碎）。
- 续跑策略：模型只回文本、没有交付文档/画布操作时，自动再跑一轮 nudge；Plan 模式仍缺
  文档则返回 `doc_not_written`，不伪装成澄清。
- 工具结果必须整形（`compact_envelope`）：剥离 `mbt`/`svg`，节点截断 24、数据截断 40，
  追加 `state`。
- 会话：`CompactingSession` 保留最近 18 条 + 确定性摘要；>80 条压缩；不额外调用 LLM。
- 取消：`/agent/cancel` → `RunResultStreaming.cancel()`；SSE 必须始终有终态事件。

## DDP

- DDP1：`DDP1` + version + salt16 + nonce24 + XChaCha20-Poly1305(zstd(payload))，
  AAD = header。Argon2id m=19*1024 KiB, t=2, p=1, len=32。
- DDP2：`DDP2` + version + CRC32LE + zstd(payload)。
- 与 deepDesign Studio 的 Rust codec 已做双向交叉验证；改 codec 必须重新对账。
- 文档标记：`<!-- nondesign:design {...} -->` / `<!-- nondesign:docs {...} -->` 放文末；
  JSON 中 `>` 必须转义为 `\u003e`，否则引擎注释扫描器会在 `-->` 截断。

## Flutter 约定

- 状态：`AppStore extends ChangeNotifier`（provider）。所有会改项目的异步操作串行
  经过 store；不要绕过 store 直接调 API。
- **右栏结构（2026-11-13 拆分）**：`right_panel.dart` 只是 91 行壳（RightPanel 组合），
  `agent_panel.dart`（Agent 面板/时间线/模式芯片）与 `inspector_panel.dart`（检查器/
  字段件/交互/状态/页面健康）走 `part of` 共享私有类——**part 文件不得带 import**，
  全部依赖声明在库文件（right_panel.dart）头部；往右栏加类时先问归属（Agent vs
  Inspector），别再往任一 part 塞对方领域的东西。
- 画布：`CanvasView` + `ArtboardPainter`；节点命中区用透明 `Positioned` 覆盖；
  拖动只更新本地 ghost，松手才发 `move` op。
- 设计令牌：`core/theme.dart` 的 `NonPalette` 是唯一颜色源；不要在 widget 里散落硬编码色。
- 本地化：当前简体中文；文案集中在 widgets，后续接入 i18n 时再抽表。
- **快捷键（2026-11-13 起，全平台）**：绑定与展示标签统一走 `core/keys.dart` 的
  `modKey()`（macOS=meta/⌘，Windows/Linux=control/Ctrl）与 `modCombo()`（标签把
  ⌘→Ctrl+、⇧⌘→Ctrl+Shift+）。**不要在 workspace/docs 里手写
  `SingleActivator(..., meta: true)`、也不要散落硬编码 ⌘ 标签**——加新快捷键时绑定与
  标签各取一处助手，两处缺一就是「按得动但看不见」或「看得见但按不动」。
- 平台壳：macOS 为主开发目标；`linux/` `windows/` 由 `flutter create
  --platforms=linux,windows` 生成（2026-11-13），窗口标题 NoNDesign，快捷键即经
  keys.dart 自适应；跨平台构建未在本机验证（无 Linux/Windows 环境），首次在对应平台
  构建时先补依赖再跑门禁。
- macOS Runner 已关闭 App Sandbox（本地 Python 子进程 + `~/.nondesign`）；不要随手加回
  sandbox 而不补 network client / app container。
- 窗口：`MainFlutterWindow.swift` 固定在主显示器居中，避免 macOS 恢复离线显示器坐标。
- **动效与控件一致性（2026-11-13）**：时长/曲线只取 `NonMotion`
  （fast 120 / base 180 / slow 240ms，easeOutCubic）——不要散落裸 Duration。
  对话框统一 `showNonDialog`
  ——注意：nonSelect 底层是 **M3 DropdownMenu**（菜单行 MenuItemButton，高度可收敛
  32px）；经典 DropdownButtonFormField 有运行时断言 `itemHeight >= 48`（2026-11-14
  红屏实证，analyzer 抓不到 runtime assert——改它必须跑一次真机/测试打开菜单）。
  entry 高度对必须规范化：`Size.fromWidth` 的隐含高度是 Infinity，与
  `maximumSize` 高 32 组成 min>max 即崩。回归锚：test/nonselect_test.dart。（fade+scale 入场，barrierColor 可覆盖）；下拉统一
  `nonSelect(context, …)`（菜单配色/圆角 10/高度上限 280/箭头一处定义，
  inspector/settings 全部 DropdownButtonFormField 走它）；右键菜单与浮层走
  popupMenuTheme/dialogTheme 全局主题。改这些助手时全端生效，别在调用点
  再写一份局部样式。

- **外部智能体 ACP（2026-11-14）**：`server/acp_bridge.py`——模块名**不能叫
  acp.py**（会遮蔽 site-packages 的 SDK 包 `acp`，ImportError circular）。
  官方 SDK `agent-client-protocol`（导入名 acp）路由按 **kwargs 直传 hook
  参数（`session_update(session_id, update)` / `fs_write_text_file(session_id,
  path, content)`），`on_connect` 是同步调用；SDK 的 Client 钩子事件必须桥进
  prompt 的 sink 队列（曾因双队列丢失全部 delta——单会话串行 prompt，一个
  sink 即可）。权限自动放行（选第一个 allow 选项）+ fs 读写限制在工作区。
  目录在 `AGENT_CATALOG`（Claude Code/Codex/Kimi/Pi/StepCode/MiniMax/OMP/
  Pivot(置灰)/Gemini/Qwen/Cline），PATH 探测即可见；锚点
  `scripts/wf/test_acp_client.py`（fake agent 裸 JSON-RPC over stdio）。
  Flutter：设置 → 外部智能体选 agent（acpAgentId 持久化），AgentPanel 发送
  分流 `store.runAcp`，会话按 projectPath+agent 幂等，切项目/新建即失效重建。

- **tool 配对消毒（2026-11-14，真机 400 实证）**：压缩（`_compact`/`_budget`）
  按条目数切历史会把 `function_call` 与 `function_call_output` 切散 → chat wire
  上就是 `role 'tool' must be a response to a preceding message with
  'tool_calls'` 的 400。`context.py::_sanitize_tool_pairing` 在 `_load` 与
  `get_items` 出口只保留 call_id 双向齐全的配对（孤立调用=中断未执行、孤立结果=
  调用被压缩，一并剔除），旧会话文件自动自愈。**改压缩逻辑时不要去掉这层消毒**；
  锚点：`scripts/wf/test_context_sanitize.py`。默认步数 300（server 默认、
  Dart 默认、UI clamp 4–600）。

- **半程任务恢复（2026-11-14）**：`recovery.json` 在运行期也落盘——run 起点
  （force）、每次 doc_written、每次 preview canonical 渲染成功、终态 finally
  各写一档；快照新增 `run:{phase,instruction,startedAt,partialMbt}`，非空即
  「上次运行未正常结束」。重启后 `restoreRecovery` **优先用 partialMbt**
  （构建进度）并提示阶段（撰写文档/构建原型/调整原型）。改恢复路径时守住：
  ① doc_written 不置 dirty，别把 guard 收回 `dirty` 条件；② 终态快照必须
  force（agentBusy=false 后 run 标记随之清空）。

- **字阶与文案（2026-11-14）**：全应用 8 档字阶 10/11/12/13/15/18/22/34，
  10px 可读性地板（17 档→8 档已重映射 254 处）；加文案先查这档表。运行时栈名
  （Flutter/Python 等）不进产品文案。已知缺口（深度优化轮分诊 deferred，审查轮
  2026-11-14 复核：③ 已修，⑦⑧ 新增 to_thread 遗漏已修，其余仍成立，勿丢）：
  ① `applyOp` 无在飞排队——HTTP 在飞窗口内第二个 op 以陈旧 mbt 提交并覆盖
  （resize 在飞+方向键可复现，high）；② `_jumpHistory` 无在飞守卫（连按 ⌘Z
  合并成一步，与①同根应随队列一并做）；~~③ `_NodeInteractionsEditor._entries`
  拉回从未渲染~~（已修，2026-11-14：补渲染 + 解绑按钮；父级 `_ensureNodeInteractions`
  与本组件各自独立拉取 session_interactions 仍是重复请求，未合并——数据流改动
  留给专门一轮）；④ SSE 事件契约零测试锚点（已部分缓解：`test/store_test.dart`
  覆盖 applyOp/undo/redo 核心路径，`/agent/run` SSE 事件契约本身仍无锚点）；
  ⑤ 多选拖拽 N 次串行 HTTP（正解是引擎批量 move op，上游提 issue）；⑥ 门禁加固
  （capability/ddp 不验 sha、compileall 只查语法、ddp_check 依赖本机文件路径）；
  ~~⑦ `list_templates`/`list_themes` 两端点 + agent compose 阶段 + `_list_templates`
  工具函数未经 `to_thread`~~（已修，2026-11-14）；~~⑧ `_cleanup_document` 三处
  `engine.session` 同步调用，每轮 run 收尾必经路径~~（已修，2026-11-14：函数改
  `async def` + 逐处 `to_thread`）。

- **语义树全局关闭（2026-11-14，崩溃报告实证）**：Flutter macOS 引擎的
  AccessibilityBridge 在 macOS 27.2 上被 AX 客户端激活后，逐帧语义更新触发
  `doesNotRecognizeSelector` → SIGABRT（MacOSEventsFromAXEvent）。应用根级
  `ExcludeSemantics`（main.dart）整树排除——引擎侧不再产生 AX 事件，崩溃
  不可达；副作用是被 AX 激活驱动的 ~20fps 空闲泵帧同步消失（216 帧/10s →
  21 帧/10s）。上游修复前不要移除；若要恢复 a11y，先在 macOS 27 上真机回归
  崩溃面。设置镜像：`saveSettings` 双写 `~/.nondesign/settings.json`
  （含 apiKey，本机单用户）——SharedPreferences 落 plist，探针/e2e 从镜像
  文件读。

- **实测与模式纪律（2026-11-14，VM Service 探针实证）**：性能判断先跑
  `/tmp` 式探针（websockets 连 VM Service：getMemoryUsage + setVMTimelineFlags
  'all' + getVMTimeline 的 B/E 配对时长），别靠感觉。debug（JIT）与
  profile（AOT）实测差距：帧均 7.7ms→1.1ms、p90 6.4→0.6ms、堆 122MB→16MB、
  单消息尖峰 1660ms→53ms——**「卡」的第一嫌疑永远是 debug 模式本身**，
  `./scripts/dev.sh --profile` 是真实手感。仍待查：空闲期 ~20fps 的
  BeginFrame 泵（profile 下 1.1ms/帧无害，但来源未定位）；SEMANTICS 每帧
  走查（canvas 已 ExcludeSemantics，面板未包）。

- **综合性能面（2026-11-14）**：长列表一律 `ListView.builder` 惰性构建
  （Agent 时间线、设置模型清单——`ListView(children:)` 每次通知重建全部行）；
  时间线行淡入只给尾部 3 行（`animate` 参数），旧行从 1 起始，滚动回看不重播；
  SSE 分片直接窄化 `Map<String, dynamic>`（dart:convert 本就产出该形状，
  `Map.from` 整表拷贝是每秒几十次的白功）；NodeImageCache 经 ResizeImage
  钳 1024px 解码宽（原图几十 MB 位图进内存只为一枚头像节点）；
  CanvasView 的 layoutBoards 按 envelope 列表引用记忆化（identical 检查）。

- **渲染性能（2026-11-13）**：① SSE 思考/文档流式增量一律走 80ms 合帧
  （`_deltaBuffer`/`_thinkingBuffer` + Timer，事件头 `_handleAgentEvent` 入口与
  finally 双处冲刷）——逐片 notifyListeners 是全树重建放大器，别再手写直推。
  ② 画布两个 painter（FlowPainter 整层 + ArtboardPainter 每板）都有
  RepaintBoundary 图层隔离；painter 的 shouldRepaint 是字段级对比，改 painter
  参数时必须保持（新增字段记得加进对比链）。

## 测试与验收

- `flutter test`：Welcome / Canvas / Workspace / Docs 无头渲染 + SSE 解析。
- Python 端到端：`server/main.py` + mock OpenAI SSE → Plan/Build 两种 run，
  验证文档、生成页面、preview、cleanup、canonical 回写。
- 引擎：`scripts/sync_engine.py` 的 render 探针；`server/engine.py` 的
  render/apply/generate/session 冒烟。
- DDP：Python 自身往返 + Rust `vendor` 交叉（历史验证；当前仓库不再 vendored Rust）。
- 改引擎版本：更新 `scripts/sync_engine.py` 锚点 → 跑 sync → 跑 Python/Flutter 测试。
- **本地集成模式（ENGINE_LOCAL 标记，2026-11-13，用户决策）**：`engine/ENGINE_LOCAL`
  （gitignored，一行=构建路径）在场时 sync 默认取 `../moonviz-dev` 本地构建——dev 跑法
  持续使用本地引擎，rebuild 后重跑 `scripts/sync_engine.py` 即接回；**不会被 Release
  产物静默覆盖**。标记缺省才回落「校验现存 / 拉取 Release」；`--release` 是显式
  发布锚定（标记在场时告警）。引擎自报版本可能滞后 dev 构建（0.2 自报 0.1.11），
  能力面以 manifest `build_line`（行为探针判定）为准。首次设锚：
  `.venv/bin/python scripts/sync_engine.py --local ../moonviz-dev/_build/wasm/release/build/wasm/wasm.wasm`。

## 已知限制（v0.1）

- 单一 OpenAI 兼容路径（用户决策 2026-11-13：撤掉 LiteLLM/Anthropic 桥；MiniMax 走 OpenAI 兼容 /v1）。非 openai 协议在 store 与 agent.py 双层拦截。
- API Key 明文存本机 SharedPreferences；Keychain 未接。
- 画布图片节点已支持网络图（cover 裁切，异步缓存）。
- 演示模式使用 flow + 内置返回；尚未接 `session_event` 手势全量状态机。
- 本地服务无鉴权，仅绑定 loopback；不要暴露到局域网。
- App Sandbox 关闭；正式分发需重新设计 App Container/entitlement。

## 版本

`VERSION` = `0.1.0`（唯一版本源；`app/pubspec.yaml` 与 `server/main.py` 同步）。
