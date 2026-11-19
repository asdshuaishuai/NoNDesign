# UI 修复台账（已完结 2026-11-18）

> **状态：已全部修复并验证，本文件只留作历史记录**（见下文「修复记录」）。
> 头部的下列指令已失效，审查/修复工作流**不要再**把它当作开放问题或高优先
> 项重复认领：
>
> > ~~迁移工作流（去 Python 化 + 文案人性化）结束后修复。全域审查工作流必须把这两条当作
> > **已确认的高优先问题**，不得降级为风格偏好。~~（历史指令，2026-11-18 修复后失效）

## UI-1 桌面主页默认不显示右侧栏

- 位置：`app/lib/widgets/desktop_shell.dart:137-204`
- 现象：无项目（Welcome 主页）时，`DesktopShell` 仍渲染右侧 `ChatRail`（展开态）或
  `ChatRailStrip`（折叠态）。用户截图：桌面首页右侧整块聊天栏常驻。
- 期望：主页（`!store.hasProject && !docsVisible`）**不出现右侧栏**；Welcome 全宽显示。
  进入工作区/项目后才出现右侧栏，并保持现宽度、折叠、拖拽与持久化行为。
- 边界：主页的一句话输入、最近项目、工作台、作品集入口全部保留；不要借此改主页布局。

## UI-2 右侧栏「聊天」与「NaN」重复

- 位置：`app/lib/widgets/chat_rail.dart:19-28`（`kRailTabs`）、`:150-160`（`_body`）
- 现象：右侧栏有三个 tab：聊天 / NaN（界面显示为 NaN）/ 检查。聊天与 NaN 都是聊天与
  任务指令入口，功能重复。
- 期望：右侧栏收为两个 tab：**NaN** 与 **检查**。NaN 就是聊天 + 任务指令执行的窗口
  （承载 `ChatStreamView`，含进度卡/产物卡）；不再保留独立的「聊天」tab。
  检查 tab 的节点选中/显式切换行为保持不变。
- 连带：`kRailTabChat` / `kRailTabAgent` 常量与 `_openWithTab` / `_setTab` /
  `_observeRightTab` / `ShellStorage` 的 tab 归一化要一起收口；旧存档里的 `chat` 值
  迁移到 `agent`，不得出现空面板。
- 普通 Workspace 的 348 右栏（`right_panel.dart`）本来就只有 NaN + 检查，与本次裁决一致；
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

## 架构裁决（用户 2026-11-18；本段实施细节已被 2026-11-19 裁决取代）

> ⚠️ **历史批注（2026-11-19）**：本段描述的中性模块入口实现已被后续裁决推翻——
> 提交 **84ad0c4**「项目落地直接进所属工作区（删除模块选择界面）」删除了 hub 与
> ProjectHubView（`store._projectLandingView` 已不存在，新建/打开项目直进所属
> 工作区）；提交 **9f17c0b** 撤掉了 ⌘5–⌘7 直跳键（全库 `app/lib` 已无 Digit5–7
> 处理器）。现行规则见 AGENTS.md「工作台切换 = 项目切换」：工作台跟项目走，
> 切换入口是顶栏项目下拉。下文按当时事实保留，仅 ⌘5/⌘6 表述作废。

设计 / 热应用 / 3D / 视频 = **四个相互独立的模块**；NaN（chat agent）可以控制每个模块；
唯一的模块间关联是 **设计 → 热应用**（可以从设计生成热应用）。设计与 3D、视频无关联。

实施内容（历史）：

- **项目落地不默认设计**（已被 84ad0c4 取代）：`store._projectLandingView` —— 桌面壳
  （macOS/Windows/Linux）新建/打开项目落在中性模块入口 `hub`（ProjectHubView：四个模块
  卡片 + NaN 提示）；移动端壳保持设计工作面。运行完成后跳设计画布展示结果是显式行为，
  保留。
- **设计工具条解耦**（⌘5/⌘6 表述已随 9f17c0b 作废）：设计画布工具条只保留热应用入口
  （设计 → 热应用是唯一合法关联）；3D / 视频入口只在主页工作台与顶栏项目下拉
  （原写法「全局 ⌘5/⌘6 快捷键」已删）。
- **发布资产修复（实测发现）**：`assets/three/`（3D 预览模板 + three.module.js）与
  `assets/a2ui_web/`（A2UI 官方 Web 渲染器页面）此前未声明进 `flutter.assets`，
  release 包里 3D 工作台报「预览文件缺失」、A2UI Web 卡不可用。已加入 pubspec 并验证
  3D 规范 → 生成 → WebView 渲染全链可用。

验证（历史）：`flutter analyze` 0 error/warning；当时 `flutter test` 820 项全绿。
> ⚠️ 该计数含已删除的 project_hub_test（hub 随 84ad0c4 退场，测试一并删除，
> `grep -rn "project_hub" app/lib app/test` 现为零命中）；820 已不代表当前测试总数，
> 引用本段数字时以当时批次为准，不要当作现行基线。

## 新能力：由产品原型生成可验证的热应用（2026-11-18，已实施）

> **本文已迁出**：完整规格（服务面、字节级覆盖验证、verified 如实上报、入口与
> 失败语义）现维护在 [docs/hotapp-from-prototype.md](hotapp-from-prototype.md)，
> 请以那份文档为准。要点回顾：设计 → 热应用是一等能力，生成结果做**字节级
> 覆盖验证**，验证未过时如实上报 `verified=false` 不冒充成功；入口在热应用
> 工作台顶栏「由原型生成」按钮（2026-11-19 起唯一化，设计画布工具条只留
> 进入热应用工作台的入口，见 hotapp-from-prototype.md §4）。agent 工具
> `hotapp_from_prototype` **尚未实施**（待加
> AgentWorkspaceServices/RPC 面，见新文档「后续」一节）。

验证记录（历史，2026-11-18）：hotapp_local_test 新增 3 例（全量覆盖
verified=true / 缺画板如实上报 / 缺连线如实上报），全量 `flutter test` 823 项
全绿，analyze 0 error/warning。
