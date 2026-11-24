# plan-chat-stream-shell.md — Chat Stream 主体 + 艺术架 + 画中画工作区（方案）

> 状态：**已实施（2026-11-17）；Python 服务已退场（2026-11-18，批次 15）** ·
> 用户裁决来源：本轮对话原文（「本体升级成 chat stream 的类 dots 应用…存在艺术架，
> 专门放生成的热应用、原型交互 UI、视频和 3d 小玩意…彻底剔除 python 的 agents sdk…
> 桌面端的工作区是常驻的，移动端右划呈现在聊天式上方覆盖，画中画形态…桌面端同样保留
> 本地 agent 检测和使用」）。§5 逐条记录实际范围与残留。依赖文档：
> docs/plan-dart-agent-migration.md（agent 循环 Dart 化，本方案的前置）。
>
> **退场注记（2026-11-18）**：文中 `server/nonapp_agent.py`、
> `server/nonapp_routes.py`、`/hotapp/*` 端点等描述是当时实现的历史记录；这些
> Python 文件与路由已随 `server/` 删除。热应用 / `.nonapp` 的生成、导入导出、
> 本地库与预览现在全部在 Dart 客户端完成（`hotapp_service.dart`、
> `nonapp_library.dart`、`nonapp_package.dart`）。S3 的「服务端」章节只作历史
> 背景，不要据此恢复 HTTP 端点。

## 0. 结论先行

1. **渲染层判定**：HTML 热应用与 A2UI（`a2ui_flutter`，genui 的官方继任者）**并存、自适应分派**，
   不是互相替代。两者**都只在 NaN 平台内运行**、都是一等小应用：HTML = 自包含单文件载荷
   （零外链，包内即开）；a2ui = 原生富交互层（表单/输入/滑杆/日期 + DataModel 绑定 + 动作回流）。
   **「文件即应用」= 把小应用打包成 `.nonapp` 单文件压缩包，分享给其他 NaN 用户，对方用我们
   的应用打开即可用**（格式定义见 §1.1）。
2. **信息架构**：主交互面从 Welcome 升级为 **chat stream**（聊天流）；生成物不再只有「进工作区」
   一条路，而是以卡片落在聊天流里；**艺术架**（Art Shelf）是产物的常驻货架面（热应用 / 原型交互
   UI / 视频 / 3D 小件）；**工作区**与之并存——桌面常驻分栏，移动端（pad 按屏幕尺寸自适应）
   右划以**画中画浮窗**覆盖在聊天上方。
3. **agent 循环层**：彻底剔除 Python agents SDK——migration plan 的 P0–P2 从「路线图」升格为
   **本方案的硬前置**；聊天流的 agent 是 `genkit` 工具循环（2026-11-23 由 ai_sdk 迁移）。
4. **桌面保留本地 agent 检测**（ACP 检测/使用不动，移动端维持禁用）。

## 1. 渲染层评估：a2ui_flutter 能否替代 HTML 热应用

**答案：不能替代，是互补。**（注意命名史：热应用旧名「A2UI 小应用」指 HTML 路线；协议意义的
A2UI 是 a2ui_flutter 实现的那套。下文 A2UI 均指协议/包。）

| 维度 | HTML 热应用（现状） | A2UI surface（a2ui_flutter 0.3.0） |
| --- | --- | --- |
| 运行平台 | NaN 平台内（WebView 载体） | NaN 平台内（原生 surface 载体）——两者相同 |
| 打包分享 | 单 HTML 即应用本体；`.nonapp` 包内 `payload/index.html` | `.nonapp` 包内 `payload/surface.json`（A2UI 消息序列）+ 初始 DataModel |
| 组件复杂度 | LLM 手写全部 UI 逻辑，复杂有状态件（表单校验/日期/滑杆联动）质量方差大 | 原生 Material 件：TextField/CheckBox/ChoicePicker/Slider/DateTimeInput，**校验（props.isValid）与路径绑定（DataModel）内置** |
| 交互回流 | 无结构化回流（app 内逻辑自洽） | 动作自动打包当前状态回 agent，**交互循环免费** |
| 视觉动画 | canvas/SVG/CSS 母语，动画小件的主场 | 无此能力（基础目录无动画/图表；图表需自定义 CatalogItem） |
| 成熟度 | 已上线（SQLite 桥 + 作品集） | v0.3.0 早期（genui 已弃用，官方继任；API 会动） |
| 安全面 | 服务端 CSP/零外链门 | 官方明示 agent 消息视为不可信输入（openUrl 需显式回调） |

**自适应分派标准（生成时由模型决策，落盘标记）**：
- 视觉/动画/演示类（canvas、粒子、叙事）→ `renderer: html`
- 数据交互类（表单、清单、仪表盘、多步向导、需 agent 续写的交互）→ `renderer: a2ui`
- 生成器提示词同步教分派规则；复杂图表两侧都要自定义（HTML 手写 canvas / a2ui 自定义
  `ComponentImplementation`）。

### 1.1 文件即应用 v2：`.nonapp` 单文件包（用户澄清 2026-11-17）

**定义修正**：文件即应用 ≠ 跨出平台可移植。两种渲染器的小应用**都只在 NaN 平台内运行**；
「文件即应用」= 把小应用**打包成 `.nonapp` 单文件（单文件压缩包）**，分享给其他 NaN 用户，
对方用我们的应用打开即用。

- **容器**：`.nonapp` = zip 单文件，内含——
  - `manifest.json`：`formatVersion / id / name / title / renderer(html|a2ui) / createdAt / minAppVersion`
  - HTML 载荷：`payload/index.html`（全内联零外链单文件）
  - a2ui 载荷：`payload/surface.json`（createSurface / surfaceUpdate / dataModelUpdate 消息序列）
    + `payload/data.json`（DataModel 初始态）+ 可选 `payload/prompt.txt`（接收方有 agent 运行时
    时可续跑交互）
- **约束**：a2ui 打包应用只能使用**内置组件目录**——自定义 `CatalogItem` 是编译期 Dart 代码，
  不能随文件分发；需要自定义组件的 a2ui 应用随应用版本走。
- **打开路径**：OS 文件关联 / 拖拽 / 应用内打开 → 校验 manifest → 安装进本机热应用库：
  - 有关联服务器：`/hotapp/import` 落入 hotapps 目录 + 作品集登记 → 进工作台；
  - 纯离线：**a2ui 直接内存打开（零服务依赖）**；HTML 解压到本地缓存经 file:// WebView 打开
    （SQLite 桥降级提示）。
- **数据边界**：业务数据（SQLite / DataModel 运行时数据）不随文件走——分享的是应用本体，
  接收方获得全新实例（v1 诚实边界；可选快照携带留 v2+）。

## 2. 信息架构（三面一体）

```
┌─ Chat Stream（主交互面）────────────────────────┐
│ 聊天流：用户 brief → agent 卡片流                │
│   · 进度卡（步骤/工具调用）                      │
│   · A2UI 交互卡（确认表单/参数选择 → 回流续跑）   │
│   · 产物卡（热应用/原型/视频/3D → 进艺术架）      │
├─ 艺术架 Art Shelf（常驻货架面）──────────────────┤
│ 热应用（html/a2ui 双载荷）/ 原型交互 UI / 视频 / 3D │
│ 即现有 portfolio 的升级：货架式布局 + 分类签 + 打开 │
├─ 工作区 Workspace（并存面）──────────────────────┤
│ 桌面：常驻分栏（chat 与 workspace 同屏）          │
│ 移动 pad：chat 为主，右划 → workspace 画中画浮窗   │
└─────────────────────────────────────────────────┘
```

- **Chat Stream**：`genkit` 工具循环（P0；2026-11-23 由 ai_sdk 迁移）驱动；消息模型 = 文本 + 卡片（复用现有
  TimelineEntry 的分类经验，但改为聊天流布局）；A2UI 交互卡经 a2ui_flutter 的
  `MessageProcessor/A2uiSurface` 渲染，动作用 `unifiedOutbound` 回流。
- **艺术架**：portfolio_view 升级——货架布局（大卡 + 分类签：热应用/原型/视频/3D），
  数据源不变（portfolio index + 自动补扫），入口从「标题栏/主页卡」升为一级面。
- **工作区**：现有 workspace 结构不动；变的是**宿主布局**——
  - 桌面（≥1100 宽）：chat（左）+ workspace（右）常驻分栏，可折叠。
  - 移动（含 pad 竖屏）：chat 全屏为主面；右缘右划手势拖出 workspace 浮窗（画中画：
    可拖动、可缩放、可全屏展开、可收回），浮窗内是完整工作区。
  - pad 横屏按宽度自适应：≥1100 走桌面分栏，否则走浮窗模式。

## 3. Agent 循环：剔除 Python agents SDK（吸收 migration plan P0–P2）

- P0（必做，本方案前置）：`core/dart_agent.dart` 三模式（PLAN/Build/Refine）统一循环，
  工具语义以 server/agent.py 为权威对齐；thinking 方言表移植。
- P1：chat stream 事件契约（进度卡/产物卡/A2UI 卡）替代 SSE 时间线事件。
- P2：`server/agent.py` 与 openai-agents 依赖删除；服务端收缩为「引擎门 + IO + 资产服务」。
- 服务运行时层（wasmtime/DDP/ffmpeg）去留见 migration plan §5 P3，不在本方案范围。

## 4. ACP（桌面本地 agent）保留

- 检测（`acp_bridge` detect/probe）与使用方式不变；chat stream 里 ACP agent 与内置循环
  同一卡片流（发送前按当前选择分流，现状逻辑平移）。
- 移动端维持禁用（既有裁决）。

## 5. 施工切分（建议顺序）——实施情况

> 2026-11-17 全部落地：S0/S1 随提交 `2261e53` 入库；S2/S3/S4 与 migration P1 同日在工作树
> 完成（未提交）。各条「残留」= 已知未做/未验证项，不是待办承诺。

- **S0 渲染底座**：✅ 已实施。引入并钉住 `a2ui_flutter` 0.3.x；`widgets/a2ui_card.dart` 封装
  `A2uiCard`（AppTheme 主题化 + 动作回流接 store）。**偏差**：0.3.0 的 `MessageProcessor` 尚无
  统一 `unifiedOutbound` 形参（官方示例超前于已发布 API），现以 `onAction` + `outboundListener`
  双通道等价透出，升级到带该形参的版本时只改这一个文件。
- **S1 Chat Stream 面**：✅ 已实施。消息模型（文本卡 / 进度卡 / A2UI 卡 / 产物卡）+ 聊天流视图
  （`widgets/chat_stream.dart`）+ `chat.json` 会话持久化；`settings.chatStreamHome` 默认开 =
  启动停在聊天流，设置里「聊天流 / 经典 Welcome」可切回（main.dart:94/149、settings_dialog.dart:700）。
- **S2 艺术架**：✅ 已实施。portfolio 重写为货架面：5 个固定分类签（全部/热应用/原型/视频/3D）+
  每个非空分类一行横向货架（卡 260×176，行高 176）；四类产物一键直达——hotapp → `hotAppLoadOnOpen`
  + `plugin:hotapp`、video → `videoLoadOnOpen`（mp4 绝对路径）+ `plugin:video`、three →
  `threeLoadOnOpen` + `plugin:three`、prototype → `store.openProjectPath`（needPassword 弹一次口令框
  重试）。视频为**真播**：`widgets/video_player_surface.dart`（WebView，有服务器走 `/video/mp4?path=…`、
  离线 `loadFile`，错误覆盖层），服务端新增 `server/video_media.py`（GET+HEAD，双根白名单，
  accept-ranges/Range-206）。3D 项目行内「删除 3D 项目…」（二次确认 → `/three/delete` + 作品集条目
  清理，删当前项目回空态）。res-1/res-2 按 ask 定义落实（3D 删除按钮与 WebKit macOS/iOS 守卫；
  预览就绪 `_previewReady` 单门 + 截图/四方位统一 `_captureReady`）。
  **残留**：macOS 真机播放/seek 未人工验收（widget 测试只断言 URL、创建参数与错误覆盖层）；
  Windows/Linux 无 `webview_flutter` 插件 → 应用内播放降级为路径提示；「在文件夹中显示」按平台
  能力隐藏而非运行时探测；`scripts/wf/test_shelf_media.py` 因 `test.sh` 属禁改文件未进门禁循环；
  产物卡「存入艺术架」未做成独立动作（数据源仍是 portfolio index + 自动补扫，生成即入架）。
- **S3 双后端热应用 + 文件即应用 v2**：✅ 已实施（服务端 + Flutter + 三平台关联）。
  - 服务端：`server/nonapp_agent.py`（formatVersion=1、5 条目白名单、条目数/单条/总解压三重上限、
    临时目录 + 每应用 asyncio 锁内 `.trash` → `os.replace` 原子落位）+ `server/nonapp_routes.py`
    （POST `/hotapp/export`、`/hotapp/import`；GET `/hotapp/a2ui/{name}`、`/hotapp/info/{name}`）；
    `server/main.py:50` 以可选 `try/except include_router` 循环挂载（模块缺失只打 stderr，不拖垮服务）。
  - 客户端：`nonapp_package.dart`（客户端预筛比服务端更严：18 组件白名单 + 零外链扫全文，与
    `hotapp_agent._html_ok` 的漂移风险已注释登记）、`nonapp_cache.dart`、`nonapp_intake.dart`
    （`nc/open` 通道 + 冷启动队列，已挂 `main.dart:116` 的 `NonAppIntakeHost`）、`api_nonapp.dart`、
    `nonapp_import.dart`、`nonapp_viewer.dart`；`hotapp_workspace.dart` 按 `/hotapp/info` 分派
    a2ui → 原生 viewer / html → WebView，离线 `file://` + SQLite 降级横幅，导入/导出入口（窄屏收进「⋯」）。
  - **平台关联做到哪一步**：macOS 自有 UTI `com.nondesign.nonapp` + CFBundleDocumentTypes +
    `nc/open` 通道（MainFlutterWindow）+ AppDelegate openFiles/open 转发——已声明；iOS
    CFBundleDocumentTypes / UTImportedTypeDeclarations + LSSupportsOpeningDocumentsInPlace +
    UIFileSharingEnabled + registrar 通道（冷启动 URL 与 `open:options:` 同一队列）——已声明；
    Android manifest VIEW（content/file + zip / nondesign-package mime + `.nonapp` pathPattern）与
    SEND 两组 filter + MainActivity 通道 / SharedPreferences 冷启动队列——已声明。
  - **残留**：Linux/Windows 文件关联（`.desktop`/MimeType、Windows 注册）**未声明**；iOS/Android
    「导出」禁用（无 share-sheet 插件）；移动离线缓存落 `systemTemp`（系统可清，重开需重导入）；
    离线导入不持久化、动作续跑/拖拽投递不做；a2ui 深层 props schema 未校验（浅层结构门只挡已知崩因）；
    Android **未构建验证**（`flutter doctor` 报 cmdline-tools missing / license unknown / maven 超时，
    `flutter build apk` 未执行，仅 manifest XML 解析 + analyze）；macOS 双击 / iOS「文件」打开 /
    Android mime 上报等真机项未人工验收。
- **S4 画中画工作区**：✅ 已实施。`widgets/shell_host.dart` 的 `ChatWorkspaceHost`：≥1100 宽
  chat + workspace 常驻分栏（分隔条拖动 0.32–0.62、可折叠、可全屏，`_clampPipRect` 统一几何）；
  <1100 chat 全屏 + 右缘 20px 条带拖出画中画（`widgets/pip_window.dart`：拖动/缩放/全屏/收回，
  最小 320×280，交互期 `IgnorePointer` 吸收内容手势）；`Workspace(embedded: true)` 跳过
  TitleBar/StatusBar、和平板宽度阈值 1100/1024 分流；chat_stream 顶栏「工作区」由宿主注入
  `onOpenWorkspace`。
  **残留**：分栏比例/折叠态/浮窗几何不持久化（重启回默认）；iPad 分屏跨 1100 会在两套子树间
  交换（画布不丢，滚动/选中态可能复位）；无键盘快捷键；聊天流「工作区」按钮不再隐式建项目
  （有意变更，旧 `openWorkspace` 语义保留在无宿主/产物卡路径）；窄屏右缘条带会覆盖聊天面最右
  20px；浮窗高度 <262 隐藏 Rail（避免 280 最小高度 RenderFlex 溢出）。
- 回归（本轮实跑；其中 `test_shelf_media.py` / `test_nonapp.py` / `test_hotapp.py`
  / `test_server_routes.py` 已随 `server/` 在 2026-11-18 退役，仅作历史记录）：
  S2 = `flutter test` 8 文件 68 项全绿 + `test_shelf_media.py`（双根 200、
  Range→206、HEAD、穿越 400）；S3 = `test_nonapp.py` / `test_hotapp.py` / `test_server_routes.py`
  全绿 + nonapp 与既有测试 47 项 + `flutter build macos --debug` / `flutter build ios --no-codesign
  --debug` 成功；S4 = `test/pip_*.dart` 14 项 + 六个既有文件 63 项全绿；P1 = `agent_p1_test` /
  `agent_events_test` 12 项、`dart_agent_test` 17 项全绿。`flutter analyze` 全程 0 error /
  2 warning（均为既有 rail.dart / settings_dialog.dart 项），info 84–92（主要是仓库既有
  `material` deprecated_member_use 噪音；≤74 的 info 门在本机基线下不可达，与本方案无关）。

## 6. 风险

1. `a2ui_flutter` 0.3.x 早期，API 会动——封装一层 `A2uiCard` 隔离，升级只改封装。
2. 提示词膨胀：A2UI 系统 prompt 官方自述 3000–5000+ token——用 `a2ui_agent` 的生成器按
   所需组件片段裁剪，避免吃掉小模型上下文。
3. 双渲染后端的生成质量分派：先规则后学习（复杂度启发式起步，误分派允许用户在聊天里
   一句话改渲染器重生成）。
4. PiP 浮窗与 WebView/引擎画布的手势冲突：浮窗容器统一接管手势优先级（先拖窗后内容）。
5. 剔除 Python agents SDK 前必须对拍：同 brief 同模型，Dart 循环产物与 Python 产物质量
   等价才算过（对拍脚本留档）。
