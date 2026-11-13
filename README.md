# NoNDesign

AI-native 产品设计工作室：**一句话 → 产品需求设计文档 → 完整可交互原型**。

- **桌面端**：Flutter 3.50（macOS）+ 原生 CustomPainter 画布
- **智能层**：Python + OpenAI Agents SDK（`openai-agents`）
- **引擎**：MoonViz classic wasm（wasmtime 进程内宿主；version 字符串报 0.1.11，产物实际含 0.2 手势/历史/规范提取能力）
- **持久化**：DDP 单文件（zstd + Argon2id + XChaCha20-Poly1305 / 免密 CRC32）
- **模型与端点**：models.dev 快照（本地 vendored，可运行时刷新）

没有 Bun、没有 Tauri、没有 JS 运行时。Flutter 只负责界面与画布；Python 服务端负责
Agent 循环、引擎调用、DDP 与文件 IO。两者只通过本机 HTTP/SSE 交换事件与 canonical
`.mbt.md` 文本。

---

## 架构

```
┌──────────────────────────── Flutter 3.50 (macOS) ────────────────────────────┐
│  Welcome / Workspace / CanvasView(CustomPainter) / Inspector / Docs / Play  │
│  AppStore (ChangeNotifier)  ── HTTP + SSE ──┐                                │
└────────────────────────────────────────────┼────────────────────────────────┘
                                             │ 127.0.0.1:<ephemeral>
┌────────────────────────────────────────────▼────────────────────────────────┐
│ Python 3.14 · FastAPI · uvicorn                                              │
│  /engine/*   MoonViz wasmtime host（`_in` slot ABI + session cache）        │
│  /agent/run  OpenAI Agents SDK loop（tools / streaming / sessions）          │
│  /project/*  DDP codec + workspace                                           │
│  Context: static instructions → project map → design spec/docs → memory     │
└─────────────────────────────────────────────────────────────────────────────┘
```

唯一事实源是一份 canonical `.mbt.md`。人类画布操作与 Agent 操作都经引擎门校验后回写
同一份文档；DDP 只是它的认证加密容器。Flutter 的画布直接绘制引擎返回的节点树
（rect / fill / radius / text / shadow），不依赖 SVG 或 WebView。

## 快速开始

```bash
# 1) Python 依赖
python3 -m venv .venv
.venv/bin/pip install -r server/requirements.txt

# 2) 引擎产物（仓库已带 engine/moonviz.wasm；缺失时）
.venv/bin/python scripts/sync_engine.py

# 3) 模型快照（仓库已带 server/models.json；需要更新时）
.venv/bin/python scripts/sync_models.py

# 4) 启动桌面端（会自动拉起 Python 服务，使用临时端口）
cd app
flutter run -d macos
```

也可以手动启动服务（调试 / 远程前端）：

```bash
cd server
../.venv/bin/python main.py --port 8799
# Flutter:
NONDESIGN_SERVER=http://127.0.0.1:8799 flutter run -d macos
```

首次使用：右上角 **设置 → 模型与端点** 选择服务商、填入 API Key；
模型清单来自 models.dev 快照。全部服务商统一走 **OpenAI 兼容端点**（OpenAI /
DeepSeek / GLM / Kimi / MiniMax / OpenRouter…）——MiniMax 使用其 OpenAI 兼容
`/v1`；不再支持 Anthropic 原生 Messages 格式（用户决策 2026-11-13）。

## 已实现

- **AI Native 工作台**：⌘K 命令面板、NoN 侧栏、流式时间线、实时画布预览、停止/重试
- **一句话 → 文档 → 原型**：PLAN（PRD / UI 说明 / 设计规范）→ BUILD（逐屏生成 / 连线 / 自检）
- **原生画布**：多画板网格、缩放/平移、节点选择/拖动/双击改字、flow 箭头、演示模式
- **检查器**：位置/尺寸/填充/文字色/圆角/字号/透明度/可见性/flow 连接、引擎评审与自动修复
- **文档与规范**：Markdown 编辑/预览、设计令牌、把调色板写回引擎 token
- **项目**：最近项目、DDP 打开/保存（DDP1 口令 / DDP2 免密）、导出 HTML / SVG、崩溃恢复
- **上下文与缓存**：稳定前缀分层、项目地图、live state、tool 结果整形、确定性会话压缩、
  缓存命中遥测（`input_tokens_details.cached_tokens`）
- **引擎门**：HumanGate / AgentGate 分离，只读命令走检视路由，不直改文档

## 目录

```
app/                 Flutter macOS 应用
  lib/core/          API / models / store / theme
  lib/widgets/       welcome / workspace / canvas / inspector / docs / settings / play
  test/              无头 widget + SSE 测试
server/              Python 服务端
  engine.py          MoonViz wasmtime 宿主 + `_in` slot ABI
  agent.py           OpenAI Agents SDK loop + tools
  prompts.py         分层系统提示词
  context.py         项目地图 / 状态卡 / 会话压缩 / 文档标记
  ddp.py             DDP1/DDP2 codec
  main.py            FastAPI + SSE
engine/              moonviz.wasm + components.json + manifest
scripts/             sync_engine.py / sync_models.py
```

## 测试

```bash
cd app && flutter analyze && flutter test
.venv/bin/python scripts/sync_engine.py
.venv/bin/python -m compileall server
```

当前测试覆盖：DDP 1/2 往返与 Rust 交叉兼容、引擎 render/apply/generate/session、
Agents SDK plan/build 两种 run（mock LLM SSE）、sidecar→引擎→canonical 全链路、
Flutter Welcome/Canvas/Workspace/Docs 无头渲染、Dart SSE 解析。

## 安全与边界

- 服务端只绑定 `127.0.0.1`，无远程监听；这是本地桌面工具的信任边界。
- API Key 存在本机 `SharedPreferences`（明文），与当前桌面单用户场景匹配；
  OS Keychain 是后续增强项。
- macOS Runner 的 App Sandbox 已关闭（本地 Python 子进程 + `~/.nondesign` 工作目录需要）；
  正式分发可改为 App Container + 受限 entitlement。
- DDP 与 deepDesign Studio 的容器格式**字节兼容**（Rust 交叉验证通过）。

## 版本

`0.1.0` · 2026-11-13
