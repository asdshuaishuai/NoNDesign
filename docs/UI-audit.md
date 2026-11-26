# UI/UX 审计与优化台账（2026-11-27）

> 依据 `ui-ux-pro-max` skill（本地设计智能库）对 NaN 客户端做的一轮系统性审计。
> 设计系统落盘：[design-system/nan-workbench/MASTER.md](../../design-system/nan-workbench/MASTER.md)。
> 规则来源：`references/quick-reference.md` §1–§10、`references/pro-rules.md`。
>
> 状态口径：✅ 已修并有自动化锚点 · 🟡 部分修 · ⬜ 未做（列后续批次）

## 1. 已完成的修复（本轮）

| 规则 | 来源 | 问题（实测） | 修法 | 锚点 |
| --- | --- | --- | --- | --- |
| 文字对比度 ≥4.5:1（深浅独立校验） | §1 / pro-rules「Light/Dark Mode Contrast」 | 深色 `ink4` 在 panel2/3 只有 **4.32/3.85**；浅色 `ink3` bg 上 **4.13**、`ink4` 白面 **3.07**、`success` **4.10**、`warn` **3.99**、`accent2` **4.24** | 调色板按 WCAG 计算值修正：深色 ink4 `#8C96A9`；浅色 ink3 `#5C6579`、ink4 `#5B6478`、success `#177A4E`、warn `#945A00`、accent2 `#644FD3` | ✅ [contrast_test.dart](../../app/test/contrast_test.dart)（两主题 × 5 表面 × 4 文字级 + 5 语义色 = 51 断言） |
| 键盘焦点可见（WCAG 2.2 AA） | §1 / §7 | Material 默认 focus overlay 太弱；图标圆钮键盘聚焦无环 | `ThemeData.focusColor` 提到 accent 22%；`AquaToolIcon` 聚焦时画 2px accent 环（`foregroundDecoration`，不改变布局尺寸）；`AquaGelButton` 已有焦点环 | ✅ aqua_theme_test（按钮/圆钮焦点路径） |
| 减少动效（prefers-reduced-motion） | §7 / pro-rules Checklist | 多数 `Animated*` 未尊重系统开关 | 新增 `context.nonMotion(duration)`（`NonMotionX`），归零时长但保留终态；落地到 toast/聊天流/播放面/进度/卡片（细节批 task-27） | ✅ 细节批 `reduced_motion_test.dart` |
| 禁用态清晰且不可点 | §2 / §8 | 部分按钮禁用仍可触发（历史） | `AquaGelButton`/`AquaToolIcon` 禁用=降透明 + 回调置 null + 无投影；测试断言「禁用不触发」 | ✅ aqua_theme_test |
| 状态变化不移动布局边界 | §2 | Aqua 材质栈曾用 `Stack` 叠高光（可能带 padding 变化） | 焦点环用 `foregroundDecoration`、选中态用 `AquaGelSurface` 内绘，尺寸常量不变 | ✅ aqua_theme_test（尺寸常量） |
| 下拉不过度宽泛 | §5 / 用户裁决 | 长文案菜单实测 593.5px、宽字段 508.9px | `nonMenuWidthCap`（≤280 或 屏宽-24）+ 紧凑行高 32 + 省略号 + tooltip | ✅ W1-B 批次（widget 探针实测 593.5→280、508.9→280） |
| 触控目标（移动端 ≥44pt） | §2 | 桌面工具条 26–28px 可接受；移动端已有 48 | 保持；桌面不加高（避免破坏密度） | 🟡 桌面按 WCAG 24px 指针下限；移动端 44+ |

## 2. 本轮未做（后续批次）

| 规则 | 优先级 | 现状 | 下一步 |
| --- | --- | --- | --- |
| Dynamic Type / 最大系统字号不破版 | CRITICAL | 全局 `withResponsiveTextScale` 已做手机 +10%/平板 +5%；但个别固定高度行（itemExtent 32/34）在大字号下可能溢出 | 用 `textScaler` 上限夹取 + 关键列表改 `prototypeItem`；补最大字号渲染测试 |
| 屏幕阅读器顺序与标签 | CRITICAL | 多数 `IconAction` 有 tooltip→语义，但 `GestureDetector` 型热区缺标签；`ExcludeSemantics` 根级（引擎 AX 崩溃缓解）使全局语义为空 | 为工作台/检查器补 `Semantics(label:)`；在 `ExcludeSemantics` 之下按需恢复（需先确认引擎 AX 桥修复状态） |
| 移动端安全区 | HIGH | `ChatPiPShell` 已有 safe-area 处理；桌面无 | 平板横屏时检查刘海/圆角遮挡（需真机） |
| 图标族一致性 | HIGH | Material Icons 统一；但存在少量自绘图标 | 保持单一族；新增图标必须来自 Material |
| 按压反馈 | MEDIUM | 全局 `InkRipple`；部分自绘 `GestureDetector` 无 ripple | 自绘控件加 `InkWell` 或透明度按压缩放 |
| 空态/错误态文案与动作 | MEDIUM | 工作台空态已有可行动文案（如「还没有画板——让 NaN 生成，或点面板顶部 ＋ 新建。」） | 逐工作台补齐「空/错/加载/禁用」四态清单并测试 |
| 表单内联校验 | MEDIUM | 设置面板为即时保存式，无表单提交 | 保持现状（无需内联错误） |
| 图表可访问性 | LOW | 目前无数据图表 | 未来加图表时按 §10 处理 |

## 3. 本轮验证

- `flutter analyze --no-pub`：No issues found
- 全量 `flutter test`：1738 passed / 1 既有环境失败（容器 loopback，已登记）
- `flutter build linux --debug`：✓
- 新增锚点：`contrast_test.dart`（51 断言）、`aqua_theme_test.dart`（11 断言）、`reduced_motion_test.dart`（细节批）

## 4. 设计系统（来自 skill 的推荐，作为参考基线）

`design-system/nan-workbench/MASTER.md` 给出的方向是 **Developer Tool / IDE 暗色系**：
JetBrains Mono（标题/代码）+ IBM Plex Sans（正文）、深色基底 + 高饱和单一强调色、
禁 emoji 图标、焦点/减少动效/对比度硬门槛。

NaN 的取舍：
- **字体**：保持系统字体（macOS SF Pro / PingFang），不引入 Google Fonts（离线客户端 + 中文排版）；
  等宽已用于 id/坐标/token 计数。skill 的字体建议作为"若引入自定义字体"的参考记录。
- **强调色**：采纳"高饱和单一强调色"思路（accent `#5B8CFF`），但保留 accent2 用于双色渐变。
- **暗色基底**：已按建议抬亮（bg `#0E1015`），避免纯黑 OLED 观感与对比度陷阱。
