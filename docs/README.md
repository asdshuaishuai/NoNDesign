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
| [plan-cross-platform-runtime.md](plan-cross-platform-runtime.md) | **已落地（批次 A+B1，2026-11-20）**；B2–B4 待真机/退役 | WebView 统一 `webview_all`；引擎 classic wasm + JS 宿主跑进离屏 WebView；wasm_run 仅兜底；flutter_scene 不采用 |

### 1.4 方案线（**未施工**，施工前不得当作现状）

| 文档 | 状态 | 覆盖 |
| --- | --- | --- |
| [plan-creative-workbench.md](plan-creative-workbench.md) | **方案定稿，未施工** | 全局交互（右 chat + 执行/结果双面）、设计验证式原型绑定、3D 建模 + 3dcodeverse harness、视频导演台/剧本/三风格/TTS/配乐联动、强绑定强规范框架、施工批次 0–8 |
| [skills/creative-workbench/SKILL.md](skills/creative-workbench/SKILL.md) | **方案定稿，未接线** | 统一创作 skill：intake → direction → structure → build → check → blind judge → refine → deliver；spec/plan/src/artifacts/judge 标准工作区；视频/3D/设计共用 |
| [plan-music-module.md](plan-music-module.md) | **方案定稿，未施工** | 音乐（编曲）模块：score.json、五线谱编辑器、Web Audio 编译播放、music_* 工具面 |
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
| [research/openmotion-hyperframes.md](research/openmotion-hyperframes.md) | 调研结论（**只参考，不引入**） | OpenMotion（nexu-io，Apache-2.0）与 HyperFrames（Apache-2.0）：HTML-as-video、Motion.md、Agent+Studio 同源工程、版本/导出/MCP 纪律；只借规范，不做依赖/内置/套壳/导出适配器；3D 栈例外 |
| [research/line-art-animation.md](research/line-art-animation.md) | 调研结论（**只参考，不引入**） | `JDhruv14/line-art-animation`（MIT，TypeScript）：细抖墨线 + 暖纸 + 无脸小人 + 开放双笔触四肢 + 步态求解 + 昼夜反转 + 帧条验收；我们新增 `ink_line` 风格包，只借规则/参数/验收，不依赖其 TS/SVG 库 |
| [research/awesome-opus5-5-videos.md](research/awesome-opus5-5-videos.md) | 调研结论（**只参考，不引入**） | 703 条 Opus 5.5 视频 prompt 的结构/分类/技术栈统计；六段 prompt（inputs/direction/structure/build/gotchas/start）、seek(t) 确定性、beat grid、帧证据；抽象进 `creative-workbench` skill，不复制作品/服务 |
| [research/3dcodeverse.md](research/3dcodeverse.md) | 调研结论（**3D 线直接引入**） | 3DCodeVerse 论文/harness：代码即真相、四轨七运行时、plan → check → blind judge → refine、contract/connectivity/placement/shader 门、cap 规则；我们直接采用 skill/harness 契约，Python/Blender 运行时不入产品 |
| [research/pixelfx.md](research/pixelfx.md) | 调研结论（**特效子集直接引入**） | `patch-gg/pixelfx`（MIT，v0.3.1，244 effects）：color+light 双缓冲、seeded RNG、纯/模拟 effect、sprite sheet、质量 bar；只引入火焰/冰霜/风/爆炸等特效，**不引入人物/stock actor/moves** |

## 2. 决策台账（按时间倒序）

| 日期 | 裁决 | 状态 | 事实源 |
| --- | --- | --- | --- |
| 2026-11-22 | **3D 直接引入 threejs-live + 3dcodeverse**：采用 3dcodeverse 的 skill/harness 契约（Apache-2.0）与 three-live 执行面；双 authoring（`scene.json` / `src/*.js`）；Python/Blender/CadQuery/URDF 运行时不入产品，检查器用 Dart/JS 等价实现 | 方案定稿（未施工） | plan-creative-workbench §4 · research/3dcodeverse.md |
| 2026-11-22 | **视频直接引入 pixelfx 特效子集**：只取火焰/冰霜/风/爆炸/闪电等**特效**，**不含人物/角色**；`actor`/`rig`/`poses`/`act`/`moves`/on-body 特效不引入；角色仍用我们自己的 rig | 方案定稿（未施工） | plan-creative-workbench §5.3/§5.6 · research/pixelfx.md |
| 2026-11-22 | **统一创作 skill `creative-workbench`**：intake/direction/structure/build/check/blind-judge/refine/deliver 标准化；`awesome-opus5-5-videos` 只借六段 prompt 结构与质量规则，不引入作品/服务 | 方案定稿（未接线） | skills/creative-workbench/SKILL.md · research/awesome-opus5-5-videos.md |
| 2026-11-22 | **视频新增第三种风格 `ink_line`（墨线手绘）**：参考 `JDhruv14/line-art-animation` 的线稿/步态/昼夜规则，**不引入其 TypeScript/SVG 运行时**；`silly_skit` / `line_toon` 保留，Phaser 3 与 3D 例外不变 | 方案定稿（风格包） | plan-creative-workbench §5.3 · research/line-art-animation.md |
| 2026-11-21 | **外部创作工具只参考、不引入**：OpenMotion / HyperFrames 及同类第三方创作产品不做依赖、不内置进程、不套壳、不设导出适配器；只借规范/协议/交互。**3D 栈（three.js / three-live）例外**；视频工作台 Phaser 3 裁决不变（2026-11-22 增补例外：3D 线 3dcodeverse + 视频 pixelfx 特效子集，见上） | **生效（用户裁决）** | AGENTS.md · research/openmotion-hyperframes.md |
| 2026-11-20 | **愿景：代码创造世界**——人提出世界，Agent 写源代码，工作台让世界可进入、可修改、可验证、可带走；四个工作台是同一底座的四视图 | **生效（方向与取舍依据）** | vision.md |
| 2026-11-20 | **音乐编曲实现路线**：score.json 有理数时值 → 整数 tick（ppq 3840）；CustomPainter 纯 Dart 排版；Web Audio 自写 lookahead；模板+功能和声+DP 编曲，validator 硬门 | 调研结论（施工依据） | research/music-arrangement-howto.md |
| 2026-11-20 | **视频/沙雕动画实现路线**：cutout 木偶 + 30fps 整数帧 + reset/replay seek + 种子随机；TTS 主路径 sherpa-onnx，**OS 系统音色仅草稿**（Apple SLA 限制商业发布） | 调研结论（施工依据） | research/video-animation-howto.md |
| 2026-11-20 | 所有工作台**强绑定且强规范**（项目↔工作台、工作台↔事实源、Agent↔工具面、执行归属；每模块 schema+校验器+工具族+双面四件套） | 方案定稿 | plan-creative-workbench §1 |
| 2026-11-20 | 视频引入游戏引擎：**Phaser 3**（vendored），剧本 JSON 编译为引擎短片；Godot/Unity/PixiJS/Flame 否决 | 方案定稿 | plan-creative-workbench §5.0 |
| 2026-11-20 | 视频工作台：导演台 + `screenplay.json` 标准 + `silly_skit`/`line_toon` 双风格 + 离线 TTS + **视频→音乐配乐联动** | 方案定稿（2026-11-22 增补 `ink_line`，见上） | plan-creative-workbench §5 |
| 2026-11-20 | 设计 = 验证式原型**绑定项目本身**，不再列入热应用模块 | 方案定稿 | plan-creative-workbench §3 |
| 2026-11-20 | 3D = **建模**工作台（three.js；大纲/视口/检查器 + scene.json） | 方案定稿（2026-11-22 扩展：3dcodeverse harness + 双 authoring，见上） | plan-creative-workbench §4 |
| 2026-11-20 | 全局交互：右 chat 唯一对话面；工作台只做执行过程面 + 结果面 | 方案定稿 | plan-creative-workbench §2 |
| 2026-11-20 | 音乐为第五个独立模块（只做编曲） | 方案定稿 | plan-music-module |
| 2026-11-20 | **WebView 统一 `webview_all` 全平台**（macOS/iOS WKWebView、Windows WebView2、Linux WebKitGTK、Android WebView）；旧 `webview_flutter` / `webview_windows` 与 Windows 专属预览已删除 | **已实施（批次 A）**；Windows/Linux 真机复验待补 | plan-cross-platform-runtime §1 |
| 2026-11-20 | **wasm 主路径 = 引擎 classic wasm + JS 宿主跑进离屏 WebView**；wasm-gc 只作未来快路径；wasm_run 降为启动失败兜底 | **已实施（批次 B1，macOS WKWebView 实跑通过）**；B4 退役待 B2/B3 | plan-cross-platform-runtime §2 |
| 2026-11-20 | **flutter_scene 本周期不用于 3D 工作台**（pre-1.0；缺建模交互层；three.js 已够用） | 裁决（可重估：≥1.0 后） | plan-cross-platform-runtime §3 |
| 2026-11-20 | 设置新增**无限步骤**（`unlimitedSteps` 哨兵，解除 4–600 步数上限与 10 分钟总时长） | **已实施**（`1259def`） | AGENTS.md · Agent 层约定 |
| 2026-11-19 | 工作台切换 = 项目切换；手机锁竖屏、平板跟随旋转；通知中心退役 | 已实施 | AGENTS.md · 产品裁决 |
| 2026-11-18 | 视频 = **代码动画**（时间线+规范编译，逐帧 SVG）；成片导出屏蔽 | 已实施 | manual-video-acceptance.md |
| 2026-11-18 | 「设计 → 热应用」为唯一模块间联动 | **已被 2026-11-20 修订**（设计原型绑定项目 + 视频→音乐联动） | hotapp-from-prototype.md（含修订注记） |

## 3. 文档之间的依赖关系（施工顺序）

```
plan-cross-platform-runtime §1（已落地：webview_all 全平台）
        │  wasm 主路径同步切换：classic wasm + JS 宿主跑进离屏 WebView（§2）
        ├──> plan-creative-workbench §2（执行/结果双面；统一 creative-workbench skill）
        ├──> plan-creative-workbench §4（3D 建模视口 + 3dcodeverse plan/check/judge；three-live）
        ├──> plan-creative-workbench §5（视频导演台 / Phaser；`ink_line` 走 Canvas2D 笔触；pixelfx 特效子集）
        │          └──> plan-music-module（§5.5 配乐联动依赖音乐模块）
        └──> wasm_run B4 退役（待 Windows/Linux/移动真机复验）
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

最后对账：2026-11-22（与 `AGENTS.md`、`vision.md`、四份方案、已实施契约头部交叉核对；
**批次 A（webview_all 全平台）+ B1（classic wasm WebView 宿主）已落地**；
macOS WKWebView 真实集成测试通过；Windows/Linux/移动真机复验与 wasm_run B4 退役
仍是未清项；OHOS 离屏 WebView 缺口已登记；本轮新增 `creative-workbench` skill、
3dcodeverse 3D harness、pixelfx VFX 子集与 `ink_line` 风格调研——除 3D 线
（three-live + 3dcodeverse）与 pixelfx 特效子集外，仍坚持「只参考、不引入」）。
