# NaN 文档总纲（唯一索引）

> 本文件是 NaN 仓库的**文档地图 + 决策台账 + 状态口径**。
> 执行手册是根目录 [AGENTS.md](../AGENTS.md)——改代码前先读它；本文负责回答
> 「有哪些文档、哪些已实施、哪些只是方案、某个裁决记在哪里」。
>
> 维护规则：**新增/改名/状态变化必须同步本索引**；文档之间不复制事实，
> 只做链接（move, not copy）。每个文档头部必须写状态行（格式见 §4）。
>
> **方向以 [vision.md](vision.md) 为主**；`docs/research/` 下的调研只作制作参考，
> 不反过来定义方向。

## 1. 文档分层

### 1.0 愿景（方向与取舍的唯一事实源）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [vision.md](vision.md) | 生效（2026-11-20） | **代码创造世界**：四个工作台是同一底座的四视图、七条原则、反愿景、成功判据、决策五问 |

### 1.1 执行手册

| 文档 | 说明 |
| --- | --- |
| [AGENTS.md](../AGENTS.md) | 架构边界、产品裁决、常用命令、测试门禁、已知限制——**改代码前必读** |

### 1.2 产品与设计裁决（长期有效）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [copy-glossary.md](copy-glossary.md) | 生效中 | 用户可见文案的唯一术语表（内部词禁令、错误码人话映射） |
| [design-system.md](design-system.md) | 生效中 | 视觉与交互原则（配色、层级、动效、组件语言） |
| [plan-plugins.md](plan-plugins.md) | 定稿（按轨推进） | 插件轨道边界：Figma / 3D / 视频 = 客户端能力；RSI 质量环 = design 内置 |

### 1.3 已实施契约（描述现状，改动需同步测试）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [hotapp-from-prototype.md](hotapp-from-prototype.md) | 已实施（2026-11-18；**2026-11-20 方案将验证式热应用移入设计项目，未施工**） | 原型 → 可验证热应用的确定性覆盖检查 |
| [remote-desktop-rpc.md](remote-desktop-rpc.md) | 已实施（批次 10） | 「连接桌面」RPC 宿主：token、loopback、方法表 |
| [three-live-sandbox.md](three-live-sandbox.md) | 已实施（three-live 1.4.0，2026-11-19） | 3D 沙箱执行面、CSP 边界、双执行路径 |
| [video-clip-contract.md](video-clip-contract.md) | v1 生效（**引擎短片/Phaser 为规划的第三渲染面**） | 动效合成 HTML/CSS/JS 短片契约 |
| [manual-video-acceptance.md](manual-video-acceptance.md) | 生效中 | 视频工作台人工验收清单（代码动画裁决） |
| [context-cache.md](context-cache.md) | 生效中 | Agent 上下文与缓存策略（Dart 进程内） |
| [chat-live-preview.md](chat-live-preview.md) | 已实施（2026-11-19） | 聊天流内嵌工作区实况卡 |
| [wasm-run-vendoring.md](wasm-run-vendoring.md) | 现状（**退役方向已定，见跨平台方案 §2**） | wasm_run vendoring、离线构建、平台库校验 |
| [plan-chat-stream-shell.md](plan-chat-stream-shell.md) | 已实施（2026-11-17） | Chat Stream 主体 + 艺术架 + 画中画工作区 |
| [plan-dart-agent-migration.md](plan-dart-agent-migration.md) | 已实施（2026-11-18） | 去 Python：Dart Agent 循环迁移 |
| [plan-a2ui-web-spike.md](plan-a2ui-web-spike.md) | spike 完成（未接产品） | 官方 A2UI Web 渲染器可行性 |

### 1.4 方案线（**未施工**，施工前不得当作现状）

| 文档 | 状态 | 覆盖 |
| --- | --- | --- |
| [plan-creative-workbench.md](plan-creative-workbench.md) | **方案定稿，未施工** | 全局交互（右 chat + 执行/结果双面）、设计验证式原型绑定、3D 建模、视频导演台/剧本/双风格/TTS/配乐联动、强绑定强规范框架、施工批次 0–8 |
| [plan-music-module.md](plan-music-module.md) | **方案定稿，未施工** | 音乐（编曲）模块：score.json、五线谱编辑器、Web Audio 编译播放、music_* 工具面 |
| [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) | **方案定稿（2026-11-20）** | WebView **目标 = `webview_all` 全平台**（含 Linux/OHOS）；当前 `webview_flutter` + `webview_windows` 为过渡/参考；wasm 宿主 → 渲染引擎 wasm SDK 跑进 WebView（Linux 过渡期保留原生）；flutter_scene 本周期不采用 |
| [plan-flutter-3.50-adoption.md](plan-flutter-3.50-adoption.md) | backlog（待排期） | Flutter 3.50 采纳清单 |

### 1.5 历史快照 / 审查（只读，不作为待办）

| 文档 | 性质 |
| --- | --- |
| [funct-chain-review-2026-11-18.md](funct-chain-review-2026-11-18.md) | 功能链路完整性审查（基线 9865ac3，只审不改） |
| [migration-baseline.md](migration-baseline.md) | 迁移批次 00 基线（门禁数字快照） |
| [round7-residuals.md](round7-residuals.md) | 第七轮残留清单（历史基线） |
| [pending-ui-fixes.md](pending-ui-fixes.md) | UI 修复台账（已全部修复，仅留档） |

### 1.6 运维 / 发布

| 文档 | 内容 |
| --- | --- |
| [release-installers.md](release-installers.md) | 安装包来源、本地复现、签名与限制 |
| [release-notes.md](release-notes.md) | Release 页面文案模板（`__VERSION__` 占位） |

### 1.7 专题研究（可施工工艺）

| 文档 | 状态 | 内容 |
| --- | --- | --- |
| [research/music-arrangement-howto.md](research/music-arrangement-howto.md) | 调研结论（供施工） | 编曲：score.json 时间模型、CustomPainter 五线谱、SMuFL/Bravura、Web Audio 调度与六音色配方、模板+DP+规则编曲、校验与 A/B、许可证 |
| [research/video-animation-howto.md](research/video-animation-howto.md) | 调研结论（供施工） | 视频动画/沙雕短剧：工艺与节奏量化、screenplay/rig/clip 数据模型、cutout 木偶、30fps 确定性运行时、离线 TTS（sherpa-onnx；OS 音色仅草稿）、口型/音效、导出与验收 |
| [research/tts-offline-appendix.md](research/tts-offline-appendix.md) | 原始调研全文 | 离线 TTS 的平台细节、模型/许可证对照、时间对齐、viseme、音效与配乐联动（视频文档 §5 的出处） |

## 2. 决策台账（按时间倒序）

| 日期 | 裁决 | 状态 | 事实源 |
| --- | --- | --- | --- |
| 2026-11-20 | **愿景：代码创造世界**——人提出世界，Agent 写源代码，工作台让世界可进入、可修改、可验证、可带走；四个工作台是同一底座的四视图 | **生效（方向与取舍依据）** | vision.md |
| 2026-11-20 | **音乐编曲实现路线**：score.json 有理数时值 → 整数 tick（ppq 3840）；CustomPainter 纯 Dart 排版；Web Audio 自写 lookahead；模板+功能和声+DP 编曲，validator 硬门 | 调研结论（施工依据） | research/music-arrangement-howto.md |
| 2026-11-20 | **视频/沙雕动画实现路线**：cutout 木偶 + 30fps 整数帧 + reset/replay seek + 种子随机；TTS 主路径 sherpa-onnx，**OS 系统音色仅草稿**（Apple SLA 限制商业发布） | 调研结论（施工依据） | research/video-animation-howto.md |
| 2026-11-20 | 所有工作台**强绑定且强规范**（项目↔工作台、工作台↔事实源、Agent↔工具面、执行归属；每模块 schema+校验器+工具族+双面四件套） | 方案定稿 | plan-creative-workbench §1 |
| 2026-11-20 | 视频引入游戏引擎：**Phaser 3**（vendored），剧本 JSON 编译为引擎短片；Godot/Unity/PixiJS/Flame 否决 | 方案定稿 | plan-creative-workbench §5.0 |
| 2026-11-20 | 视频工作台：导演台 + `screenplay.json` 标准 + `silly_skit`/`line_toon` 双风格 + 离线 TTS + **视频→音乐配乐联动** | 方案定稿 | plan-creative-workbench §5 |
| 2026-11-20 | 设计 = 验证式原型**绑定项目本身**，不再列入热应用模块 | 方案定稿 | plan-creative-workbench §3 |
| 2026-11-20 | 3D = **建模**工作台（three.js；大纲/视口/检查器 + scene.json） | 方案定稿 | plan-creative-workbench §4 |
| 2026-11-20 | 全局交互：右 chat 唯一对话面；工作台只做执行过程面 + 结果面 | 方案定稿 | plan-creative-workbench §2 |
| 2026-11-20 | 音乐为第五个独立模块（只做编曲） | 方案定稿 | plan-music-module |
| 2026-11-20 | **WebView 目标 = `webview_all` 全平台**（macOS/iOS/Android/Windows/Linux/OHOS）；当前 `webview_flutter` + `webview_windows`（Windows WebView2）为**过渡/参考**；批次 A stash 待恢复 | 方案定稿；Windows 过渡已落地 | plan-cross-platform-runtime §1 |
| 2026-11-20 | **wasm → 渲染引擎 wasm SDK 跑进 WebView**；wasm_run 分四批退役 | 方案定稿，未施工 | plan-cross-platform-runtime §2 |
| 2026-11-20 | **flutter_scene 本周期不用于 3D 工作台**（pre-1.0；缺建模交互层；three.js 已够用） | 裁决（可重估：≥1.0 后） | plan-cross-platform-runtime §3 |
| 2026-11-20 | 设置新增**无限步骤**（`unlimitedSteps` 哨兵，解除 4–600 步数上限与 10 分钟总时长） | **已实施**（`1259def`） | AGENTS.md · Agent 层约定 |
| 2026-11-19 | 工作台切换 = 项目切换；手机锁竖屏、平板跟随旋转；通知中心退役 | 已实施 | AGENTS.md · 产品裁决 |
| 2026-11-18 | 视频 = **代码动画**（时间线+规范编译，逐帧 SVG）；成片导出屏蔽 | 已实施 | manual-video-acceptance.md |
| 2026-11-18 | 「设计 → 热应用」为唯一模块间联动 | **已被 2026-11-20 修订**（设计原型绑定项目 + 视频→音乐联动） | hotapp-from-prototype.md（含修订注记） |

## 3. 文档之间的依赖关系（施工顺序）

```
plan-cross-platform-runtime §1（WebView 目标：webview_all 全平台）
        │  过渡期：webview_flutter + webview_windows；Linux 由 webview_all 补齐
        ├──> plan-creative-workbench §2（执行/结果双面）
        ├──> plan-creative-workbench §4（3D 建模视口，three.js）
        ├──> plan-creative-workbench §5（视频导演台 / Phaser）
        │          └──> plan-music-module（§5.5 配乐联动依赖音乐模块）
        └──> plan-cross-platform-runtime §2（引擎 wasm SDK 跑进 WebView）
```

* 音乐模块与视频引擎互不阻塞；**视频→音乐联动（批次 7）必须等音乐模块批次 1–4 完成**。
* wasm 宿主迁移（B1–B4）不阻塞工作台 UI 批次，但会替换引擎执行面——两者不要并行改
  `EngineService` 与工作台。

## 4. 状态行规范（新文档必须遵守）

文档第一行标题后紧接引用块，写明：

```
> 状态：**已实施（日期，提交）** / **方案定稿，未施工** / **施工中（批次）** /
> **spike 完成（未接产品）** / **历史快照（只读）** / **backlog（待排期）**
```

* **已实施**的文档写「现状契约」，可以直接引用文件:行；改动必须同步测试并回填本文。
* **方案定稿**的文档写「目标态」，不得使用现在时描述未落地的行为；施工后回填
  「落地锚点」（文件:行）并把状态改为已实施。
* 历史快照只追加日期与结论，不追改细节（避免把历史改写成现状）。
* 跨文档引用用相对路径；涉及裁决冲突时以**日期更新的裁决**为准，并在旧文档头部
  加「已被 X 修订」注记（本次 hotapp-from-prototype 与 plan-music-module 已按此处理）。

## 5. 对账清单（改文档时一起检查）

1. `AGENTS.md`：产品裁决表、能力矩阵、已知限制是否与本文 §1/§2 一致。
2. `copy-glossary.md`：新增用户文案是否有人话映射（不出现内部词）。
3. 已实施契约文档：文件路径、测试名是否仍存在（`flutter test` 会暴露）。
4. 方案文档：施工批次与状态行是否一致；未施工的批次不得写成已完成。
5. 本索引：新增文档必须进 §1 对应分层，状态变化必须同步 §2。

---

最后对账：2026-11-20（与 `AGENTS.md`、`vision.md`、三份方案、五份已实施契约头部交叉核对；
已合并用户实现（workspace 生成链路 + Windows WebView2），三分支统一到 `6c05b0e`；
WebView **目标仍是 `webview_all` 全平台**，Windows `webview_windows` 作过渡/参考；
批次 A 已 stash、待恢复）。
