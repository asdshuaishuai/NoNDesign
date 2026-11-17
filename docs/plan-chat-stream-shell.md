# plan-chat-stream-shell.md — Chat Stream 主体 + 艺术架 + 画中画工作区（方案）

> 状态：**方案（待实施）** · 2026-11-17 · 用户裁决来源：本轮对话原文（「本体升级成 chat stream 的类
> dots 应用…存在艺术架，专门放生成的热应用、原型交互 UI、视频和 3d 小玩意…彻底剔除 python 的
> agents sdk…桌面端的工作区是常驻的，移动端右划呈现在聊天式上方覆盖，画中画形态…桌面端同样保留
> 本地 agent 检测和使用」）。依赖文档：docs/plan-dart-agent-migration.md（agent 循环 Dart 化，
> 本方案的前置）。

## 0. 结论先行

1. **渲染层判定**：HTML 热应用与 A2UI（`a2ui_flutter`，genui 的官方继任者）**并存、自适应分派**，
   不是互相替代。HTML = 可移植的通用格式（任何 WebView 可开，文件即应用的根基）；a2ui = 活在
   NoNDesign 运行时里的**富交互层**（原生表单/输入/滑杆/日期 + DataModel 绑定 + 动作回流）。
2. **信息架构**：主交互面从 Welcome 升级为 **chat stream**（聊天流）；生成物不再只有「进工作区」
   一条路，而是以卡片落在聊天流里；**艺术架**（Art Shelf）是产物的常驻货架面（热应用 / 原型交互
   UI / 视频 / 3D 小件）；**工作区**与之并存——桌面常驻分栏，移动端（pad 按屏幕尺寸自适应）
   右划以**画中画浮窗**覆盖在聊天上方。
3. **agent 循环层**：彻底剔除 Python agents SDK——migration plan 的 P0–P2 从「路线图」升格为
   **本方案的硬前置**；聊天流的 agent 就是 `ai_sdk_dart` 内置循环。
4. **桌面保留本地 agent 检测**（ACP 检测/使用不动，移动端维持禁用）。

## 1. 渲染层评估：a2ui_flutter 能否替代 HTML 热应用

**答案：不能替代，是互补。**（注意命名史：热应用旧名「A2UI 小应用」指 HTML 路线；协议意义的
A2UI 是 a2ui_flutter 实现的那套。下文 A2UI 均指协议/包。）

| 维度 | HTML 热应用（现状） | A2UI surface（a2ui_flutter 0.3.0） |
| --- | --- | --- |
| 可移植性 | **任何 WebView/浏览器可开**；文件即应用的载体 | 只能活在 NoNDesign 运行时（离开 app 无渲染器） |
| 组件复杂度 | LLM 手写全部 UI 逻辑，复杂有状态件（表单校验/日期/滑杆联动）质量方差大 | 原生 Material 件：TextField/CheckBox/ChoicePicker/Slider/DateTimeInput，**校验（props.isValid）与路径绑定（DataModel）内置** |
| 交互回流 | 无结构化回流（app 内逻辑自洽） | 动作自动打包当前状态回 agent，**交互循环免费** |
| 视觉动画 | canvas/SVG/CSS 母语，动画小件的主场 | 无此能力（基础目录无动画/图表；图表需自定义 CatalogItem） |
| 成熟度 | 已上线（SQLite 桥 + 作品集） | v0.3.0 早期（genui 已弃用，官方继任；API 会动） |
| 安全面 | 服务端 CSP/零外链门 | 官方明示 agent 消息视为不可信输入（openUrl 需显式回调） |

**自适应分派标准（生成时由模型决策，落盘标记）**：
- 视觉/动画/演示类（canvas、粒子、叙事）→ `renderer: html`
- 数据交互类（表单、清单、仪表盘、多步向导、需 agent 续写的交互）→ `renderer: a2ui`
- 文件格式 v2（`.nonapp`）：载荷带 `renderer` 字段；HTML 载荷任何运行时可开，a2ui 载荷仅
  NoNDesign 运行时可开（打开前如实提示）。
- 生成器提示词同步教分派规则；复杂图表两侧都要自定义（HTML 手写 canvas / a2ui 自定义
  `ComponentImplementation`）。

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

- **Chat Stream**：`ai_sdk_dart` 内置循环（P0）驱动；消息模型 = 文本 + 卡片（复用现有
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

## 5. 施工切分（建议顺序）

- **S0 渲染底座**：引入 `a2ui_flutter`（+ `a2ui_agent` 的提示词生成/流解析，接 ai_sdk_dart 流）；
  封装 `A2uiCard` widget（AppTheme 主题化 + unifiedOutbound 回调接 store）。
- **S1 Chat Stream 面**：消息模型 + 聊天流视图 + 卡片类型（进度/A2UI/产物）+ 会话持久化；
  替换 Welcome 成为默认主面（设置可切回经典 Welcome）。
- **S2 艺术架**：portfolio → Art Shelf 货架面；产物卡「存入艺术架」动作。
- **S3 双后端热应用**：生成器分派提示词 + `renderer` 字段 + 文件格式 v2 + a2ui 载荷的
  打开/导出/导入全链。
- **S4 画中画工作区**：移动右划手势 + PiP 浮窗（拖动/缩放/全屏/收回）；桌面常驻分栏。
- 每步带回归（widget 测试 + 门禁五件套）；a2ui_flutter 钉住小版本（0.3.x）防 API 漂移。

## 6. 风险

1. `a2ui_flutter` 0.3.x 早期，API 会动——封装一层 `A2uiCard` 隔离，升级只改封装。
2. 提示词膨胀：A2UI 系统 prompt 官方自述 3000–5000+ token——用 `a2ui_agent` 的生成器按
   所需组件片段裁剪，避免吃掉小模型上下文。
3. 双渲染后端的生成质量分派：先规则后学习（复杂度启发式起步，误分派允许用户在聊天里
   一句话改渲染器重生成）。
4. PiP 浮窗与 WebView/引擎画布的手势冲突：浮窗容器统一接管手势优先级（先拖窗后内容）。
5. 剔除 Python agents SDK 前必须对拍：同 brief 同模型，Dart 循环产物与 Python 产物质量
   等价才算过（对拍脚本留档）。
