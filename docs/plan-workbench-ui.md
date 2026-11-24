# 工作台交互姿态与 UI 布局独立适配计划（2026-11-24）

> 状态：**方案（2026-11-24，已开工：UI-0–UI-3 落地，UI-4 首批落地）**。目标：四个工作台不再共用一套
> 「内容区布局」，而是**每个工作台拥有自己的交互姿态与布局规格**；外壳仍共享（标题栏/
> 左侧图标轨/右侧 NaN chat/底部状态栏不变），**变化只发生在每个工作台的内容区**。
> 按 **设计 → 3D → 视频 → 音乐** 分批施工；**热应用暂不改动**。
>
> 相关：[plan-creative-workbench.md](plan-creative-workbench.md) §1/§2 ·
> [workspace_chrome.dart](../app/lib/widgets/workspace_chrome.dart)（共享外壳）·
> [workspace.dart](../app/lib/widgets/workspace.dart)（设计面现状）·
> [three_workspace.dart](../app/lib/widgets/three_workspace.dart) ·
> [video_workspace.dart](../app/lib/widgets/video_workspace.dart) ·
> [plan-next-iterations.md](plan-next-iterations.md)（视频双轨/3D 后续）·
> [docs/README.md](README.md) §1.4。

## 1. 裁决口径（与旧「四工作台外壳统一」的关系）

* **保留共享外壳**（2026-11-20 裁决）：标题栏、左侧图标轨、右侧 chat、底部状态栏
  四工作台一致；这是「同一个 NaN」的边界，不因本计划推翻。
* **内容区独立**（2026-11-24 用户方向）：每个工作台内容区的**交互姿态、主区形态、
  面板种族/位置、底部条、工具条、快捷键姿态、响应式折叠策略**各自适配，不复制设计壳
  的 252/348 面板几何与「左栏=设计项目面板」假设。
* **热应用冻结**：本轮不重排 hotapp 工作台布局；共享外壳回归测试继续覆盖它。

「交互姿态」在本计划里指：用户进入该工作台后**第一眼做什么、主区是什么、辅助面放在
哪里、常用动作怎么触达**；不是换皮，也不是全局快捷键重写。

## 2. 每工作台交互姿态（目标态）

| 工作台 | 第一姿态 | 主区 | 左侧 | 右侧 | 底部/顶部 |
| --- | --- | --- | --- | --- | --- |
| **设计** | 画布优先（Design Board） | 画板画布 + 画板条 + 验证原型结果面 | 项目/画板/图层/文档/历史（可折叠） | NaN 检查（检查器/对话） | 顶部画板条/生成/验证；底部状态栏（与外壳共享） |
| **3D** | 视口优先（Modeling Viewport） | 3D 视口（Orbit、网格、拾取、gizmo move/rotate/scale、吸附、相机视角） | 场景大纲/资产树（节点、part、灯光、相机） | 检查器（变换/材质/几何/相机） | 顶部建模工具条（选择/移动/旋转/缩放/网格/吸附）；底部 pass/门/测量状态条 |
| **视频** | 时间线优先（Director Desk） | 预览画布（16:9/9:16）+ 运输条 | 剧本/场/镜头树（常规视频）或 scene/镜头树（3D 视频） | 镜头检查器（镜头语言/时长/台词/cue/风格） | 底部时间线（镜头条+轨道）；顶部风格/画幅/运行 |
| **音乐** | 谱面优先（Score Desk） | 五线谱/钢琴卷帘编辑区 | 声部/乐器/轨道列表 | 和声/力度/检查器 | 底部运输条（播放/节拍器/循环）+ 混音器；顶部调号/拍号/速度 |

**3D 视频** 与常规视频共用「导演台」外壳姿态，但预览执行面不同（three-live vs
现有 v1 clip/矢量）；布局规格允许按 `videoMode` 切换左侧树与检查器字段，不复制两套壳。

## 3. 布局规格模型（建议实现）

新增 `app/lib/core/workbench_layout.dart`（纯 Dart，可测）：

```dart
enum WorkbenchKind { design, three, video, music }

enum PanelPolicy { hidden, docked, sheet }

class WorkbenchLayout {
  final WorkbenchKind kind;
  final PanelPolicy left;
  final PanelPolicy right;
  final bool rail;        // 外层共享外壳的左轨是否显示
  final bool bottomBar;   // 内容区自带底部条（时间线/状态条）
  final double leftWidth;
  final double rightWidth;
  final LayoutBreakpoints breakpoints; // 每个工作台自己的折叠断点
}

WorkbenchLayout resolveWorkbenchLayout({
  required WorkbenchKind kind,
  required double width,
  required double height,
  bool embedded = false,
});
```

* **不再**在 `workspace.dart` 里用一套硬编码 252/348/700/1024 决定所有工作台；
  设计面先从 `resolveWorkbenchLayout` 取值，后续 3D/视频/音乐各自接管。
* 每个工作台一个 `WorkbenchContentShell`（内容区骨架），只保证「主区 + 可选侧栏 +
  可选底栏」的挂载点，不规定内部样式。
* 共享外壳仍由 `WorkspaceChrome`/`WorkspaceMainArea` 提供；内容 shell 只占主区。

## 4. 分批施工（按用户顺序）

### UI-0 规格与骨架（1–2 天，**已完成 2026-11-24**）

- `core/workbench_layout.dart` + 单元测试：四工作台断点/面板策略/默认宽度；
  `docs/README` 与测试锚点。
- 不改视觉；只提供可测试的「独立规格」，设计面先从它取值且行为不变。
- 验收：布局规格正反例测试；设计面现有 `workspace_chrome_test`/尺寸测试全绿。

### UI-1 设计工作台独立适配（2–3 天，第一批视觉；**首批已落地**）

- 画布优先姿态：面板可折叠（左项目/右检查）、画板条 + 验证结果面、选区浮动工具条
  （仅画布上下文出现）；左侧面板只保留设计语义（项目/画板/图层/文档/历史）。
  **首批已落地（2026-11-24）**：`designCanvasFocus` 专注画布（画板条
  `design-focus-toggle` 切换左右面板，状态级、不改项目数据）；待做：选区浮动工具条、
  面板手势/双击收起。
- 响应式：沿用现有断点但由 `WorkbenchLayout` 提供，不在 widget 内散落魔法数；
  手机/iPad 竖屏继续走 sheet。
- 验收：设计面 widget 测试（面板折叠/画板条/浮动工具条出现/收起）；视觉截图人工复核；
  热应用布局不变。

### UI-2 3D 工作台独立适配（3–4 天；**首批已落地**）

- 视口优先：新增左侧场景大纲（来源：v2 `scene.json` 节点；legacy spec components 兜底）；
  右侧检查器按节点类型展示（变换/材质/几何/相机）；顶部建模工具条占位（选择/移动/
  旋转/缩放/网格/吸附，实际 gizmo 桥在 3D 视口批次落地后接）。
- 底栏：pass/门/测量状态条（复用现有 v2 双面数据面），不复制设计状态栏。
- **已落地（2026-11-24）**：`three_workbench_panels.dart`——legacy spec 与 v2 `scene.json`
  nodes 投影大纲、只读节点检查器（组件/材质/相机/节点）、内容区状态条；宽屏预览面改为
  「大纲 | 视口 | 检查器」三栏（使用 `WorkbenchLayout` 3D 规格）；顶部 `three-workbench-toolstrip`
  提供真实的大纲/检查器姿态开关。**待做**：属性编辑（受控 patch）、移动/旋转/缩放 gizmo、
  网格/吸附等视口交互——归 3D 视口批次，不能把布局完成说成建模可用。
- 验收：3D widget 测试（大纲选中节点 → 检查器切换；嵌入/桌面两态不溢出）；hotapp 回归。

### UI-3 视频工作台导演台布局（3–5 天；**首批已落地**）

- 左侧剧本/镜头树；中间预览 + 运输条；底部时间线（镜头条）；右侧镜头检查器。
- 常规视频与 3D 视频共用外壳，按 `videoMode` 切换树/检查器字段；3D 视频预览面等
  three-live POC（plan-next-iterations P1）通过后再接。
- **首批已落地（2026-11-24）**：`video_workbench_panels.dart`——timeline 投影镜头、
  剧本/镜头树、只读镜头检查器、按比例排布的底部时间线；生成项目/内置示例的
  `_authoringBody` 在宽屏下切导演台（预览仍是最大块），手机保留单面。
  **已补（2026-11-24）**：点树/时间线镜头会把预览跳到该镜头起点并暂停；底部时间线
  底部时间线呈现共享播放头（时间读数 + 播放状态 + 镜头条位置），与预览同源。
  **已补外部运输条（2026-11-24）**：时间线播放/暂停按钮经 `VideoAnimationController`
  驱动预览播放面，播放头随动；**待做**：3D 视频模式切换（等 three-live POC）。
- 验收：导演台 widget 测试（镜头选中 → 检查器/时间线联动；播放/暂停占位）；现有
  video_workspace 测试全绿。

### UI-4 音乐工作台（**首批已落地**；编辑器/播放/工具待后续）

- 谱面优先：五线谱编辑区 + 声部/乐器左栏 + 运输条/混音器底栏 + 和声/力度检查器。
- **首批已落地（2026-11-24）**：`pluginRegistry` 注册 `plugin:music`（顶栏项目菜单可进）；
  `MusicWorkspace` 内容布局：项目列表/轨道列表（左）、只读钢琴卷帘谱面（中）、
  乐谱检查器（右）、只读运输条（底，BPM/拍号/总 tick/时长；播放引擎不假装可点）。
  数据接 `MusicProjectStore` / `verifyMusicScore` / `compileMusicScore` 真结果。
  **待做**：五线谱编辑与放音、Web Audio 播放页、`music_*` 工具族、项目跟随/作品集。

## 5. 共享与不变量

* `WorkspaceChrome`/`WorkspaceMainArea`/`LeftPanel` 的设计语义**只属于设计工作台**；
  3D/视频/音乐不得复用 `LeftPanel`，各自实现内容侧栏。
* `WorkspaceInspector` 保留为右侧检查的挂载点，但每工作台提供自己的检查器分支
  （现有 `_ThreeInspector/_VideoInspector` 继续演进，不回到一个通用表单）。
* 快捷键：全局快捷键（⌘K/⌘,/⇧⌘F 等）保留在设计面；工作台内姿态键（如 3D
  W/E/R、视频空格播放）各自绑定，新增前先查冲突。
* 热应用（`plugin:hotapp`）**布局不动**；仍需通过共享外壳/双面回归测试。

## 6. 验收锚点（拟写）

| 批次 | 测试 |
| --- | --- |
| UI-0 | `workbench_layout_test.dart`：四工作台断点/面板/宽度；未知 kind 安全默认 |
| UI-1 | `design_workbench_layout_test.dart`：折叠/画板条/浮动工具条/手机 sheet |
| UI-2 | `three_workbench_layout_test.dart`：大纲选中→检查器；嵌入/桌面尺寸无溢出 |
| UI-3 | `video_workbench_layout_test.dart`：镜头树→时间线→检查器联动 |
| UI-4 | 随 `music_*` 契约测试 |

每批必跑：`flutter analyze --no-pub` + 相关 widget 测试 + 全量 `flutter test`；
涉及壳层/布局时同步跑 `workspace_chrome_test.dart` 与 `copy_screen_test.dart`。

## 7. 风险与依赖

* **3D 视口/gizmo 尚未落地**：UI-2 先做布局/大纲/检查器骨架，gizmo 交互等 3D 视口批次；
  不把「布局已完成」说成「建模可用」。
* **视频 3D 执行面尚未 POC**：UI-3 先接常规视频时间线；3D 视频预览面等 P1 go 后再接。
* **音乐编辑器/播放未开工**：UI-4 首批只读；放音/编辑/工具族随音乐模块后续批次，
  不把只读预览说成可播放。
* **回归风险**：四工作台共享外壳的旧测试必须继续绿；面板/断点改动先改规格再改 widget。
