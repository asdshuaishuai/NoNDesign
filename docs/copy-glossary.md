# 文案术语表（Copy Glossary）

> 批次 01 建立。**唯一事实源**：本文件 + `app/test/copy_guard_test.dart`。
> 所有用户可见文案（含按钮、标题、空态、状态栏、通知、工具名、失败提示）必须按此表措辞。
> 产品/设计签字前不允许把内部实现名暴露给用户。

## 1. 为什么需要它

旧实现把内部概念直接写进了界面：`服务器`、`DDP`、`canonical .mbt.md`、`MoonViz engine`、
`SQLite 数据库`、`wasm`、`ACP`、`blockout`、`refine-spec`、`models.dev`……
用户看不懂，也不知道「服务器未连接」到底该做什么。本表给出**用户词 ← 禁用词**的映射，
并用静态扫描守住新代码。

## 2. 术语映射（用户可见 ← 禁用）

| 用户可见 | 禁用（任何用户可见字符串里都不许出现） |
|---|---|
| 设计引擎 / 设计服务 | MoonViz、wasm、`engine_*`、AgentGate、引擎门 |
| 项目文件 | DDP、`.ddp`（**唯一例外**：系统文件选择器的扩展名过滤） |
| 源码 | MBT、`.mbt.md`、canonical |
| 设计校验 | 引擎门、AgentGate、`engine_gate_*`、`engine_unavailable` |
| 内置智能体 | Dart、agentRuntime、循环、client loop |
| 连接桌面 | 桌面服务、服务器、Python、localhost、127.0.0.1、端口 |
| 外部智能体 | ACP、CLI、PATH 探测、npx |
| 热应用 | hotapp、`.nonapp`、a2ui、SQLite（桥） |
| 3D 场景 | blockout、three.js |
| 视频 | resvg、ffmpeg、timeline |
| 离线预览 | A2UI、surface、surfaceId |
| 模型服务 | models.dev |
| 待填充 | `mock_missing`、`missing_*` 占位码 |
| 版本历史 | session_history、commit、init、log |
| 画板 / 节点 | （保留原文，不替换） |

补充禁令：

- 裸错误码（`^[a-z0-9]+(_[a-z0-9]+)+$`）不得出现在用户可见文本里；
  原始错误只能进日志或折叠的「技术详情」。
- `session_*`、`tool_*`、`mbt_*`、`ddp_*`、`wasm_*`、`agent_*`、`engine_*` 前缀同样禁止。
- `构建代号`（如 `0.5.0-fix`、`0.2-dev`、`dev@a6af848`）不进用户文案。
- 端口号、`http://127.0.0.1:…`、`listening on …` 一律不出现。

## 3. 工具名映射（`toolLabel()` 唯一出口）

内置智能体调用的工具在轨迹、时间线、通知里**必须**经 `toolLabel()` 映射；原始工具名只进
技术详情/日志（owner：批次 09，`app/lib/core/dart_agent.dart`）。

| 原始工具名 | 用户可见 |
|---|---|
| `design_op` | 设计变更 |
| `read_mbt` | 读取设计稿 |
| `inspect` | 检查 |
| `generate_page` | 生成页面 |
| `write_doc` | 撰写文档 |
| `write_design_spec` | 更新设计规范 |
| `three_*` | 3D 场景 |
| `hotapp_*` | 热应用 |
| `video_*` | 视频 |
| `nonapp_*` | 应用包 |

## 4. 失败提示映射（错误码 → 文案）

| 错误码（内部） | 用户可见 |
|---|---|
| `engine_unavailable` | 设计服务暂时不可用，请稍后重试 |
| `mbt_gate_block` | 这次改动未通过设计校验 |
| `render_failed` | 预览生成失败 |
| `download_failed` | 模型下载失败 |
| `sha256_mismatch` | 模型文件校验失败，已删除，请重试 |
| `nonapp_unsupported_version` | 应用版本过新，请更新本应用 |

规则：原始错误只放折叠的「技术详情」，默认不展开。未在表内的错误统一落到
「操作没有完成，请重试」+ 折叠详情，绝不把错误码本身当文案。

## 5. 空态与状态栏

空态固定措辞：

- 还没有作品
- 未连接（连接桌面相关）
- 还没有项目
- 还没有 3D 场景
- 还没有视频
- 还没有文档

状态栏格式：

```
版本 N · X 画板 · Y 节点 · 模型名 · 上下文 42%
```

禁止 `rev` / `ctx` / `board` / `node` 等内部缩写。

## 6. 能力不可用文案（批次 01 契约）

`app/lib/core/capability.dart` 的 `defaultCapabilityMessages` 是唯一来源，
各消费面不得自己拼句子。当前默认值：

| 能力 | 文案 |
|---|---|
| 本地设计引擎 | 本地设计引擎暂时不可用 |
| 连接桌面 | 还没有连接桌面 |
| 外部智能体 | 外部智能体只在电脑上可用 |
| 3D 场景 | 3D 场景需要先连接桌面 |
| 热应用 | 热应用需要先连接桌面 |
| 视频工作区 | 视频工作区需要先连接桌面 |
| 作品集 | 还没有作品 |
| 离线搜索 | 离线搜索模型还没有下载 |
| 应用数据 | 应用数据暂时无法保存 |
| 在文件夹中显示 | 这台设备不支持在文件夹中显示 |
| 系统分享 | 这台设备暂不支持系统分享 |
| 视频导出 | 视频导出只在电脑上可用 |

## 7. 通知（Toast）

owner：批次 04 实现 `ToastService`/`ToastHost`，06/07/08/12/13 接入。

- 形态：圆角胶囊 + 毛玻璃，顶部左侧堆叠；
- 时长分级：1–5s（成功短、失败长），可手动关闭；
- 必须保留通知历史（可回看），历史里的时间与级别不丢；
- 文案走本表；`ScaffoldMessenger.showSnackBar` 的散点调用在批次 04 之后一律移除。

## 8. 逐文件文案 owner（迁移期）

| 范围 | owner 批次 |
|---|---|
| `core/store.dart` | 05 |
| `widgets/three_workspace.dart` | 06 |
| `widgets/hotapp_*` / `nonapp_*` / `portfolio_view.dart` | 07 |
| `widgets/video_*` | 08 |
| `core/dart_agent.dart`（工具名/acp） | 09 |
| `widgets/settings_dialog.dart` / `core/models.dart` | 11 |
| `main.dart` / `welcome.dart` / `workspace.dart` / `title_bar` / `chat_stream` / `status_bar` / `theme` / `shell_host` | 12 |
| `widgets/command_palette.dart` / `docs_view.dart` / `left_panel.dart` / `inspector_panel.dart` / `play_view.dart` | 13 |
| 最终零残留 | 15 |

## 9. 守门方式

```bash
# 基线报告（批次 01 现状，不失败）
cd app && flutter test --dart-define=COPY_GUARD_STRICT=false test/copy_guard_test.dart

# 严格门（批次 13/15；有任何命中即失败）
cd app && flutter test --dart-define=COPY_GUARD_STRICT=true test/copy_guard_test.dart
```

扫描面：`app/lib/**/*.dart` 中经 `Text` / `SelectableText` / `Semantics` / `Pill` /
`TextSpan` / `RichText` / `SnackBar` / `AlertDialog` / `Tooltip` / `_toast` / `_snack` /
`showToast` / `toast` 以及命名参数 `label` / `title` / `subtitle` / `hintText` /
`helperText` / `labelText` / `errorText` / `semanticLabel` / `tooltip` 进入界面的字符串。
**prompt、注释、测试不进入扫描面**；不使用 allowlist 文件。

### 批次 01 基线

首次运行（2026-11-18）：**67 处命中**，按文件分布（实测 `awk` 统计）：

| 文件 | 命中 |
|---|---|
| `widgets/settings_dialog.dart` | 13 |
| `widgets/hotapp_workspace.dart` | 9 |
| `core/store.dart` | 9 |
| `widgets/portfolio_view.dart` | 8 |
| `widgets/welcome.dart` | 6 |
| `widgets/three_workspace.dart` | 5 |
| `widgets/workspace.dart` | 4 |
| `widgets/video_workspace.dart` | 3 |
| 其余（nonapp_* / left_panel / inspector_panel / docs_view / art_shelf_card / main） | 各 1–2 |

全部属于上表 05–15 的 owner，批次 01 只建立基线、不改写他批文件。
批次 01 新增的四个契约文件为 0 命中，并由 `copy_guard_test` 的第二条用例单独锁定。

后续批次修完自己那份后，各自的 `flutter test` 会看到更短的基线；批次 15 收尾时
严格门必须为 0。

## 10. 人工复核

五尺寸（390×844、844×390、768×1024、1024×768、1440×900）逐屏截图，覆盖启动失败、
工具轨迹、空态、设置、状态栏、通知历史；产品/设计签字后才算过。
