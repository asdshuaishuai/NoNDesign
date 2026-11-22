# NaN

AI-native 创作工作台：**一句话 → 产品需求设计文档 → 完整可交互原型**，同一工作台
还能做 3D 场景、代码动画视频与带本地数据库的 NaN 热应用。

- **桌面端**：Flutter 3.50（macOS 主目标；iOS/Android/Linux/Windows 平台壳已就位）
- **本地核心**：MoonViz classic wasm 引擎跑在**离屏 `webview_all` 会话**里
  （macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView；
  wasm_run 仅启动失败兜底）、纯 Dart DDP1/DDP2、项目库、3D / 热应用 / 视频工作台
- **内置智能体**：Dart 工具循环（`ai_sdk_dart` 直连当前服务商），画布变更仍经引擎门
- **可选「连接桌面」**：桌面 App 内的 Dart RPC 宿主（`/v1/health`、`/v1/capabilities`、
  `/v1/rpc`），默认关闭、默认只听 loopback、token 必填
- **持久化**：DDP 单文件（zstd + Argon2id + XChaCha20-Poly1305 / 免密 CRC32）
- **模型与端点**：models.dev 快照（随包 vendored，离线可用）

**没有 Python 服务、没有固定端口、没有端口文件。** 应用启动不拉起任何子进程，
默认也不监听任何端口；唯一可能的监听是你显式开启「手机连接这台电脑」（桌面设置）
后，桌面宿主绑定的临时端口（系统分配）+ 一次性连接码。仓库里保留的 Python 只是
**开发期同步工具**（`scripts/sync_engine.py`、`scripts/sync_models.py` 等），
不参与应用运行时。

---

## 架构

```
┌───────────────────────── Flutter 3.50 (macOS / iOS / Android) ──────────────────────┐
│ UI Shell：手机锁竖屏/iPad 竖屏 Chat + 画中画 · 桌面/iPad 横屏 Workspace + 右侧聊天栏 │
│           play / portfolio / plugin 全幅                                             │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ LocalCore（Dart，进程内）                                                            │
│  engine/      MoonViz classic wasm 宿主（`_in` 槽 ABI / UTF-16 读 / 会话缓存 / trap）│
│  ddp.dart     DDP1 / DDP2 编解码（Rust 实现为字节权威）                              │
│  projects     `.ddp` 保存 / 打开 / 列表（原子写）                                     │
│  3D / 热应用 / 视频 / 作品集 / 外部智能体（桌面）                                      │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ RemoteDesktop（可选，默认关闭）                                                       │
│  客户端：remote_desktop_client.dart → /v1/health | /v1/capabilities | /v1/rpc         │
│  宿主：  core/remote/desktop_rpc_host.dart（127.0.0.1:0 或显式 LAN + Bearer token）   │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

唯一事实源是一份 canonical 设计稿文本。人类画布操作与智能体操作分别经
HumanGate / AgentGate 校验后回写同一份文档；DDP 只是它的认证加密容器。
Flutter 的画布直接绘制引擎返回的节点树（rect / fill / radius / text / shadow），
不依赖 WebView。

## 快速开始

```bash
# 1) 依赖（仓库已带 engine/moonviz.wasm 与 app/assets/engine/）
cd app
flutter pub get

# 2) 启动桌面端（本地核心，不启动任何服务）
flutter run -d macos

# 评估流畅度请用 profile（AOT）——debug 是 JIT + 断言 + 调试绘制税：
../scripts/dev.sh --profile
```

首次使用：右上角 **设置 → 模型与端点** 选择服务商、填入 API Key；模型清单来自
随包的 models.dev 快照。全部服务商统一走 **OpenAI 兼容端点**（OpenAI / DeepSeek /
GLM / Kimi / MiniMax / OpenRouter…）。

更新引擎或模型快照（开发期工具，可选）：

```bash
python3 scripts/sync_engine.py      # 校验/下载 wasm，真机 render 探针
python3 scripts/sync_models.py      # 刷新 models.dev 快照 → app/assets/models.json
```

## 已实现

- **AI Native 工作台**：⌘K 命令面板、聊天流 / Agent 时间线、实时画布预览、停止/重试
- **聊天实况预览卡**：生成中的工作区以卡片形式在对话流内实时预览（取代自动画中画）
- **一句话 → 文档 → 原型**：PLAN（PRD / UI 说明 / 设计规范）→ BUILD（逐屏生成 / 连线 / 自检）
- **原生画布**：多画板网格、缩放/平移、节点选择/拖动/双击改字、flow 箭头、演示模式
- **检查器**：位置/尺寸/填充/文字色/圆角/字号/透明度/可见性/flow 连接、引擎评审与自动修复
- **文档与规范**：Markdown 编辑/预览、设计令牌、把调色板写回引擎 token
- **项目**：最近项目、DDP 打开/保存（DDP1 口令 / DDP2 免密）、导出 HTML / SVG、崩溃恢复
- **工作台跟随项目**：一个项目对应一种工作台；顶栏项目下拉按类型列项目，打开即进入对应工作台
- **3D / 热应用 / 视频**：本机服务层 + 应用内预览；热应用带本地数据库
- **设计 → 热应用**：由产品原型生成可验证的热应用——逐画板 / 逐连线字节级校验，如实上报
- **动效合成**：HTML/CSS/JS 短片渲染面，应用内实时播放（手绘简笔 / 动效排版 / 界面演示样例）
- **3D 沙箱**：three-live 沙箱 + 画廊组件在应用内真实播放（旧路径保留为降级面）
- **外部智能体**：桌面 ACP 探测与对话（移动端按设计禁用）
- **引擎门**：HumanGate / AgentGate 分离，只读命令走检视路由，不直改文档
- **交互完备**：多选/对齐/编组、右键菜单、⌘C⌘V、手势与 flow 过渡
- **全平台快捷键**：`core/keys.dart` 一处绑定（macOS=⌘，Windows/Linux=Ctrl）
- **UI 一致性**：NonMotion 动效令牌、8 档字阶、M3 DropdownMenu 统一、原生标题栏随主题

## 目录

```
app/                 Flutter 应用
  lib/core/          engine / ddp / project_service / api / store / models / theme
  lib/core/remote/   连接桌面：协议 / token / 方法表 / Dart RPC 宿主
  lib/widgets/       shell / welcome / workspace / canvas / chat / 3D / 热应用 / 视频 / 设置
  assets/            engine 产物、components 快照、models.json、3D/视频示例
  test/              flutter test（含 acceptance_local_core_test）
engine/              moonviz.wasm + components.json + manifest（构建源）
scripts/             开发期同步/对拍工具（sync_engine / sync_models / wf / engine_web_probe）
third_party/wasm_run/ vendored wasm 执行器（**仅兜底路径**；主路径不加载）
figma-plugin/        Figma 双向插件
plugins/             独立插件资产（视频制作说明等）
```

## 测试

```bash
cd app && flutter analyze --no-pub && flutter test
```

发布包桌面状态检查（构建后）：

```bash
cd app && flutter build macos --release
cd .. && dart run scripts/wf/check_desktop_release.dart \
  --app app/build/macos/Build/Products/Release/NaN.app --home /tmp/nd-home
```

它会断言：发布包内无 `.py` / `server/` / `.venv`；默认启动无监听端口、无 Python
子进程、无 `~/.nondesign/server.json`；「连接桌面」宿主契约仍是 loopback + 临时端口 +
token。

## 安全与边界

- 默认无监听；「手机连接这台电脑」默认关闭，开启后默认只绑 `127.0.0.1`，局域网需显式开关
  且每个请求都要 Bearer token。
- API Key 存在本机 `SharedPreferences`，并镜像 `~/.nondesign/settings.json`
  （探针/e2e 读取口）；明文，与当前桌面单用户场景匹配，OS Keychain 是后续增强项。
- 移动端本地引擎默认关闭，只有 `WasmRuntimeGate` 在真机 p95/内存/fuel 验收通过后才开启；
  未通过时移动端只能「连接桌面」。
- `.nonapp` 应用包打开前做格式/路径/大小/零外链校验；页面 WebView 带 CSP 与导航白名单。
- macOS Runner 的 App Sandbox 已关闭（本地文件与 `~/.nondesign` 工作目录需要）；
  正式分发可改为 App Container + 受限 entitlement。
- DDP 与 deepDesign Studio 的容器格式**字节兼容**（Rust 交叉验证通过）。

## 已知限制

- 「手机连接这台电脑」宿主已在桌面设置卡接线（启停/地址/连接码/局域网开关）；
  默认仍不监听。动态验证可覆盖「默认无监听」与显式开启后的 health/rpc。
- 视频成片导出暂时屏蔽（渲染代码保留、界面无入口）；现行视频面为代码动画 + 动效合成
  （见 `docs/video-clip-contract.md`），既有 mp4 仍由艺术架播放。
- 应用内 WebView 已统一到 `webview_all`（含 Linux/Windows）；3D/热应用/视频预览
  走同一条 `WebViewController` 路径，Windows 专属预览分支已删除。
- Android 构建已可产出 debug APK；本机无设备/AVD，WebView 本地引擎真机验收未完成。
- Windows WebView2 / Linux WebKitGTK 的离屏引擎宿主与 macOS 共用契约，需在对应
  机器跑 `integration_test/engine_webview_test.dart` 复验。

## 版本

`0.1.0` · 2026-11-18
