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
