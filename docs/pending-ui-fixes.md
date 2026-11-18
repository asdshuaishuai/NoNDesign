# 待修复 UI 问题（用户实测，2026-11-18）

> 迁移工作流（去 Python 化 + 文案人性化）结束后修复。全域审查工作流必须把这两条当作
> **已确认的高优先问题**，不得降级为风格偏好。

## UI-1 桌面主页默认不显示右侧栏

- 位置：`app/lib/widgets/desktop_shell.dart:137-204`
- 现象：无项目（Welcome 主页）时，`DesktopShell` 仍渲染右侧 `ChatRail`（展开态）或
  `ChatRailStrip`（折叠态）。用户截图：桌面首页右侧整块聊天栏常驻。
- 期望：主页（`!store.hasProject && !docsVisible`）**不出现右侧栏**；Welcome 全宽显示。
  进入工作区/项目后才出现右侧栏，并保持现宽度、折叠、拖拽与持久化行为。
- 边界：主页的一句话输入、最近项目、工作台、作品集入口全部保留；不要借此改主页布局。

## UI-2 右侧栏「聊天」与「NaN」重复

- 位置：`app/lib/widgets/chat_rail.dart:19-28`（`kRailTabs`）、`:150-160`（`_body`）
- 现象：右侧栏有三个 tab：聊天 / NoN（界面显示为 NaN）/ 检查。聊天与 NaN 都是聊天与
  任务指令入口，功能重复。
- 期望：右侧栏收为两个 tab：**NaN** 与 **检查**。NaN 就是聊天 + 任务指令执行的窗口
  （承载 `ChatStreamView`，含进度卡/产物卡）；不再保留独立的「聊天」tab。
  检查 tab 的节点选中/显式切换行为保持不变。
- 连带：`kRailTabChat` / `kRailTabAgent` 常量与 `_openWithTab` / `_setTab` /
  `_observeRightTab` / `ShellStorage` 的 tab 归一化要一起收口；旧存档里的 `chat` 值
  迁移到 `agent`，不得出现空面板。
- 普通 Workspace 的 348 右栏（`right_panel.dart`）本来就只有 NoN + 检查，与本次裁决一致；
  不要把「聊天」tab 又加回 Workspace。

## 验收

- 桌面冷启动停在主页：右侧无栏、无 44px 覆盖条。
- 打开/新建项目后：右侧栏出现，只有 NaN + 检查两个 tab；NaN 可直接发任务并看到进度卡。
- 折叠/展开、拖宽、重启后 tab 与宽度持久化仍正常。
- 手机/iPad 聊天优先壳不受影响（它们本来就没有这个桌面右栏）。

## 修复记录（2026-11-18）

两条均已修复：

- **UI-1**：`DesktopShell` 新增 `_isHome(store)`；主页分支直接返回全宽 `Welcome`，不再构建
  `ChatRail` / `ChatRailStrip`。桌面主页同时隐藏 `welcome-open-chat` 入口（`showChatEntry: false`），
  避免右栏不存在时的死按钮。
- **UI-2**：`ChatRail` 收为 `NaN + 检查` 两个 tab；`NaN` 承载 `AgentPanel`（聊天 + 任务指令 +
  执行轨迹），独立「聊天」tab 删除。旧存档 `railTab == 'chat'` 在恢复时归一化到 `agent`；
  AgentPanel 输入框新增 `agent-input` 键，供验收与测试定位。

验证：

- `flutter analyze --no-pub`：无 error / warning（仅有仓库既有的 info 级弃用提示）。
- `flutter test --no-pub`：**775 项全部通过**（含新增的主页无右栏、两 tab、旧 tab 归一化断言）。
- `flutter build macos --release --no-pub`：构建成功。
- 受影响的 5 个壳层/布局测试文件（layout_matrix / welcome_wide / chat_stream / pip_routing /
  tablet_layout）单独跑了 78 项，全绿。

未覆盖：本机屏幕锁定，未能抓取运行中窗口的实机截图；主页无右栏与两 tab 由 widget 测试锚定。

## 架构裁决（用户 2026-11-18，已实施）

设计 / 热应用 / 3D / 视频 = **四个相互独立的模块**；NaN（chat agent）可以控制每个模块；
唯一的模块间关联是 **设计 → 热应用**（可以从设计生成热应用）。设计与 3D、视频无关联。

实施内容：

- **项目落地不默认设计**：`store._projectLandingView` —— 桌面壳（macOS/Windows/Linux）
  新建/打开项目落在中性模块入口 `hub`（ProjectHubView：四个模块卡片 + NaN 提示）；
  移动端壳保持设计工作面。运行完成后跳设计画布展示结果是显式行为，保留。
- **设计工具条解耦**：设计画布工具条只保留热应用入口（设计 → 热应用是唯一合法关联）；
  3D / 视频入口在主页工作台与全局 ⌘5/⌘6 快捷键，不再挂在设计工具条上。
- **发布资产修复（实测发现）**：`assets/three/`（3D 预览模板 + three.module.js）与
  `assets/a2ui_web/`（A2UI 官方 Web 渲染器页面）此前未声明进 `flutter.assets`，
  release 包里 3D 工作台报「预览文件缺失」、A2UI Web 卡不可用。已加入 pubspec 并验证
  3D 规范 → 生成 → WebView 渲染全链可用。

验证：`flutter analyze` 0 error/warning；`flutter test` 820 项全绿（含新增
project_hub_test：桌面落 hub / hub 卡片进入对应模块 / 移动端行为不变）。

## 新能力：由产品原型生成可验证的热应用（2026-11-18，已实施）

设计 → 热应用是唯一允许的模块间关联；本能力把它做成一等能力并加上**确定性验证**：

- 服务面 `HotAppService.generateFromPrototype`：输入画板清单 + 跳转清单 + 规范文档，
  提示词要求逐屏 `<section data-screen="<id>">`、逐连线 `data-nav="<to>"`、
  本机数据走 `window.NoN.db`、零外链全内联。
- **覆盖验证是字节级检查，不是模型自评**：逐画板查段落、逐连线查 from 段落内的
  `data-nav` 目标；结构门（离线/零外链/CSP）仍由 NonAppLibrary.install 把关。
- 结果如实上报：验证未过时应用仍入库（结构门已过、不回滚），但 `verified=false`
  并给出缺失项人话摘要；UI 不冒充成功。
- 入口：设计画布工具条「由原型生成热应用」（设计视图内，紧邻热应用入口）；
  store 路径 `generateHotAppFromPrototype`（应用名由项目名派生并去重，成功/部分成功
  都会切到热应用工作台打开新应用）。
- 后续：agent 工具 `hotapp_from_prototype`（需给 AgentWorkspaceServices/RPC 面
  加方法，涉及 api.dart 远端实现与 rpc_methods 宿主，单独一批做）。

验证：hotapp_local_test 新增 3 例（全量覆盖 verified=true / 缺画板如实上报 /
缺连线如实上报），全量 `flutter test` 823 项全绿，analyze 0 error/warning。
