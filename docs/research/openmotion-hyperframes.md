# OpenMotion / HyperFrames 视频制作工具调研

> 状态：**调研结论（2026-11-21）**，供 NaN 视频工作台参考；**未接入、未安装运行**。
> 调研方式：官方 README / docs / 仓库结构 / GitHub 元数据 / npm 元数据；没有执行
> OpenMotion 或 HyperFrames 渲染，因此本文的“能做什么”是文档与源码事实，
> “效果如何”没有做画质/还原度实测。
>
> 相关：[plan-creative-workbench.md](../plan-creative-workbench.md) §5（视频工作台方案）·
> [research/video-animation-howto.md](video-animation-howto.md)（沙雕动画工艺）·
> [research/tts-offline-appendix.md](tts-offline-appendix.md)（TTS）。

## 0. 结论先行

1. **用户说的 OpenMotion，最可能是 `nexu-io/openmotion`**：OpenDesign 团队（nexu-io）
   2026-05 创建、2026-11-20 发布 v0.2.0 的开源“Agent 原生视频/创意工作台”，
   GitHub 约 **14.3k stars / 1.4k forks / Apache-2.0**。它不是单纯的剪辑器，
   而是“本地 Agent + 可编辑 HTML 工程 + Studio 时间线 + MCP 工具”的整套工作流。
2. **它的渲染底座是 HyperFrames**（`heygen-com/hyperframes`，Apache-2.0，
   约 **87.6k stars**，当前 0.9.77；OpenMotion 锁在 0.9.7 并带捕获补丁）。
   HyperFrames 的核心主张与我们的视频工作台高度同构：**视频用 HTML/CSS/JS 写，
   可 seek 的 GSAP/CSS/Lottie/Three.js 动画，headless Chrome 逐帧捕获 + FFmpeg 编码，
   同输入同输出**。
3. **OpenMotion 不是可嵌入 Flutter 的库**：它是 Node（≥22.18）+ 本地 HTTP 服务 +
   React Studio + MCP + Chromium + FFmpeg 的完整应用。直接引入会把整个
   Node/Chromium/FFmpeg 运行时塞进 NaN，和当前“Flutter + 纯 Dart 核心、
   无 JS 服务”的架构冲突，移动端基本不可行。
4. **值得借的是“规范与流程”，不是整套运行时**：
   - `Motion.md`：Agent 可读的镜头顺序/时序/转场/品牌规范（与我们的 DESIGN.md 同构）；
   - “同一份可编辑 HTML 工程”被 Agent 与 Studio 共同修改；
   - revision / version / requestId 的并发与幂等契约；
   - 导出前的 lint + 规格 + 全解码 + 代表帧校验；
   - 参考视频 → 重建 → 对照 → 再编辑的创作链。
5. **用户裁决（2026-11-21）：只参考，不引入。** OpenMotion、HyperFrames 及同类
   外部创作工具**不做依赖、不内置进程、不套壳、不设导出适配器**；只把它们的
   规范/协议/交互作为设计输入。我们是做自己的产品。**3D 栈（three.js / three-live）
   是明确例外**；视频工作台此前裁决的 **Phaser 3 + `screenplay.json`** 继续有效。

## 1. 名字澄清：至少两个 OpenMotion

| 项目 | 事实 | 判断 |
| --- | --- | --- |
| [`nexu-io/openmotion`](https://github.com/nexu-io/openmotion) | 14.3k stars；Apache-2.0；TypeScript；OpenDesign 团队；v0.2.0（2026-11-20）；“Claude Motion & CapCut 开源替代” | **本文调研对象，最可能是用户所指** |
| [`straygizmo/open-motion`](https://github.com/straygizmo/open-motion) | MIT；0 stars；React/Remotion 替代的编程视频引擎 | 同名小项目，不是这次要看的 |
| [`openmotion.design`](https://openmotion.design/) | 商业化的 prompt → 场景计划 → canvas/timeline → video/WebM/HTML | 产品形态相近，但和 nexu-io 仓库不是同一套开源实现；不要混用 |

本文以下“OpenMotion”均指 `nexu-io/openmotion`。

## 2. OpenMotion 是什么

一句话：**把你的本地 coding Agent 变成视频创作者，产出不是锁死的成片，而是
一份可继续编辑的 HTML/CSS/JS 工程 + Motion.md + 素材 + 时间线。**

官方工作流：

```text
参考视频 / 社交链接 + 品牌包 + 文案
        │
        ▼
你的 Agent（Claude Code / Codex / DeepSeek Harness / WorkBuddy …）
  拆镜头、转场、节奏，写 Motion.md，补齐素材
        │
        ▼
HTML/CSS/JS 可编辑工程（HyperFrames 格式）
  index.html + compositions/ + CSS/JS + 媒体 + Studio 数据
        │
        ├── Agent 改源码（MCP / CLI）
        └── 人在 Studio 改时间线/属性/素材
        │
        ▼
lint → HyperFrames 渲染（headless Chrome 逐帧 + FFmpeg）
        │
        ▼
MP4（+ 可编辑源码、历史版本、导出证据）
```

关键点：

- **Agent 不是黑盒生成器**：它读写同一份源码；用户可以在 Studio 里继续改。
- **参考复刻不是“套模板”**：先拆参考的镜头/节奏/动效，再用自己的品牌重建；
  是否真的还原，官方也要求用同时间点对照、实际渲染来验收。
- **BYOA + BYOK**：Agent 用你已有的；图片/视频/音乐/TTS 用你自己的 provider key；
  没有强制云账号（OpenDesign 账号/Cloud 是可选路径）。
- **模板库**：官方 v0.2.0 口径约 287 个模板、104 个 Skills、152 个 Brand Kits；
  早期 README 还有 300+ Motion.md、345 templates、891/895 catalog 等不同口径，
  数字随版本变化，接入前以当前发布物为准。
- **不止视频**：v0.2.0 已扩到 7 个 Studio（Cinema / Sound / Design 等），
  视频只是其中一个面；不要把 OpenMotion 当成单一视频 SDK。

## 3. 技术架构（真正要理解的部分）

```text
外部 Agent（MCP stdio / CLI）
        │  Skills + 工具调用
        ▼
OpenMotion 本地 Node 服务（TypeScript，node:http）
  ├─ 工程文件 / 素材 / revision / 版本 / 导出队列
  ├─ MCP 工具（phase1 约 16 个公开名，文档另有 11 个的旧口径）
  ├─ Model Gateway（BYOK：图片/视频/音乐/TTS；68 个 provider 预设）
  └─ Studio 前端（React 19 + Vite + Tailwind + Zustand + CodeMirror + Dockview）
        │
        ▼
HyperFrames 0.9.7（npm 锁定）
  ├─ @hyperframes/core：composition 解析 / 编译 / lint / 帧适配
  ├─ @hyperframes/engine：Puppeteer + 无头 Chrome 逐帧捕获
  ├─ @hyperframes/producer：编码 + 混音
  ├─ @hyperframes/studio-server：原生 Studio
  └─ CLI：preview / lint / render
        │
        ▼
MP4 + 音频；导出前做 lint、FFprobe 规格、全解码、代表帧 seek
```

**工程格式（HyperFrames 的核心）**：

- 普通 `index.html`，用 `data-*` 声明时间：
  `data-composition-id` / `data-start` / `data-duration` / `data-width` /
  `data-height` / `data-track-index` / `data-media-start` / `data-volume` /
  `data-has-audio` / `data-fade-in/out` 等。
- 动画是**可 seek 的 paused timeline**：GSAP（`window.__timelines[...]`）、
  CSS、Lottie、Three.js、Anime.js、WAAPI 或自定义 frame adapter。
- 子 composition 用 `<template>` + `data-composition-src` 挂载；
  变量用 `data-composition-variables` + `data-var-text` / `var(--id)`。
- 渲染器把时间 seek 到每一帧，headless Chrome 截图，FFmpeg 编码；
  官方明确宣称 deterministic：same input → same frames → same output。
- lint 覆盖静音视频、GSAP/CSS transform 冲突、clip 越界、子场景不可见、
  字体缺 `@font-face`、静态长镜头、布局溢出/遮挡等。

**OpenMotion 在 HyperFrames 之上加了什么**：

- Motion.md / Motion Package v0.2：风格、品牌、镜头、时序、可替换输入、验收证据；
- 参考视频复刻工作流（`openmotion-recreate`）与模板改编（`openmotion-template-to-video`）；
- Studio 前端 fork（时间线、素材、版本历史、导出、模板库、Brand Kit）；
- MCP 工程工具：create / get / edit / import_assets / export_request / list_versions /
  restore_version / export_cancel / project_archive 等；revision + version 双重校验、
  requestId 幂等、导出任务可查询/取消；
- Model Gateway：图片/视频/音乐/TTS 的 BYOK 生成与素材库；
- 导出验证：MP4/H.264/yuv420p、尺寸/帧率/时长、AAC 音轨策略、
  完整解码、首中尾 seek、哈希；失败不谎报完成。

## 4. 许可、版本与成熟度

| 项 | 事实 |
| --- | --- |
| OpenMotion 代码 | **Apache-2.0**，可商用、可修改、可再分发（保留 NOTICE/许可） |
| HyperFrames 代码 | **Apache-2.0**（npm `hyperframes` 也标 Apache-2.0） |
| OpenMotion 最新 release | **v0.2.0**（2026-11-20）；仓库另有 `v0.6.8-test.21` 等测试 tag |
| OpenMotion 版本口径 | `package.json` 是 `0.0.1`，docs 写 0.6.2/0.6.3，release 是 v0.2.0——**口径不统一，属早期项目** |
| HyperFrames 版本 | 当前 **0.9.77**（2026-11-21）；OpenMotion 锁 **0.9.7**，并带 capture 补丁 |
| OpenMotion 社区 | 14.3k stars / 1.4k forks / 101 open issues（2026-11-21） |
| HyperFrames 社区 | 87.6k stars，HeyGen 生产使用，更新非常快 |
| 运行要求 | Node ≥22.18（README 源码段落另写 26.11.1）、npm、Chromium/Chrome、FFmpeg/ffprobe；Git LFS 可选 |
| 平台 | 本地 Web 应用 + MCP/CLI；HyperFrames 另有 Mac/Windows/Linux 桌面 Studio；OpenMotion 的完整跨平台安装/验收仍在推进 |

**许可注意**：代码 Apache-2.0 不等于模板里的**品牌参考视频、字体、图片、音乐**
可以随便再分发。模板库大量是“品牌研究/参考片”，商用前要逐个核对素材授权；
AI 生成结果还受各 provider 条款约束。

## 5. 优点（对我们有启发的部分）

1. **Video as code + 可 diff**：工程是 HTML/CSS/JS + 素材，天然适合 Git、
   版本对比、Agent 读写、CI 回归；比二进制工程/锁定成片更适合“代码创造世界”。
2. **Agent 与人共享同一事实源**：Agent 改源码，人在 Studio 改时间线；不是
   “AI 生成一版、人再也无法精确修改”。
3. **规范先行**：Motion.md 把“镜头顺序、节奏、转场、可替换输入、验收证据”
   写成 Agent 可读的文档；这与我们 DESIGN.md / screenplay.json 的思路一致。
4. **参考复刻工作流**：不是只给模板，而是教 Agent 拆参考、重建、对照、
   再打包成可复用资产；这对“沙雕动画/产品片”的拉片环节很有参考价值。
5. **导出可验证**：lint + 规格 + 全解码 + 代表帧 + 哈希，不把“渲染退出 0”
   当成功；这正是我们视频工作台需要的“机械对照”纪律。
6. **MCP/版本纪律**：revision/version 双校验、requestId 幂等、导出任务可取消、
   历史版本可恢复；我们的 Agent 工具面可以直接借鉴这套契约。
7. **BYOK/本地优先**：密钥与工程留在本地，模型可换；不强制云服务。

## 6. 局限与风险（决定“不直接接入”的理由）

1. **运行时很重**：Node 服务 + React Studio + Chromium + FFmpeg/ffprobe；
   对 Flutter 桌面是几百 MB 级的额外依赖，移动端不可行；与“无 JS 服务、
   纯 Dart 核心”的现有纪律冲突。
2. **不是库，是应用**：OpenMotion 的 MCP/Studio/工程/导出队列是一个完整产品；
   要嵌入只能“外挂进程 + 本地 HTTP”，而不是 `pub add` 一个包。
3. **HyperFrames 也不是 Flutter 库**：它是 HTML 视频框架；预览可以在 WebView，
   但导出必须 headless Chrome + FFmpeg（或它的云渲染）。
4. **没有内置“看懂视频”的模型**：参考复刻靠宿主 Agent 的多模态能力/工具；
   OpenMotion 自身不提供视频理解 API，也不保证任意参考的还原度。
   “99% 还原”是官网营销口径；其 Motion.md 文档明确说六个示例不足以证明
   任意参考的保真度。
5. **代码即执行面**：HyperFrames 明确说 composition 生成器需要可信作者，
   它不是沙箱；模板/Agent 生成的 HTML/JS 在本机 Chromium 执行，
   需要隔离、CSP、路径与网络边界。OpenMotion 做了工程/revision 隔离，
   但不是通用安全沙箱。
6. **版本/文档漂移**：package 0.0.1、docs 0.6.x、release v0.2.0；
   MCP 工具数 11/16 两种口径；HyperFrames 0.9.7 vs 0.9.77。接入前必须
   锁版本、跑自己的契约探针，不能照文档数字写死。
7. **跨平台验证不完整**：官方文档明确有些集成测试仅 macOS；Windows/Linux
   完整包、真实模型任务、播放器人工听看仍是分别验收项。
8. **模板素材授权**：参考视频/品牌资产不是 Apache-2.0 自动覆盖；
   商用再分发要逐项确认。

## 7. 与 NaN 视频工作台的关系

我们的方案（[plan-creative-workbench.md](../plan-creative-workbench.md) §5）：

- 事实源 `screenplay.json`（幕/场/镜头/台词/动作/转场）；
- Phaser 3 引擎短片（vendored，自包含 HTML，30fps 固定步进，seek=reset+replay）；
- `silly_skit` / `line_toon` / `ink_line` 三风格，cutout 木偶、表情、口型、TTS、音效
  （`ink_line` 为 2026-11-22 增补的墨线手绘，走 Canvas2D 笔触分支）；
- 视频 → 音乐配乐联动；
- 视频导出是拉伸项，当前代码动画为主。

**重叠**：都用“代码/JSON 作为事实源”，都要求确定性、可编辑、Agent 可写、
导出可验证；OpenMotion 的 Motion.md/版本/导出纪律可以直接借。

**差异**：

| 维度 | OpenMotion / HyperFrames | NaN 视频工作台（计划） |
| --- | --- | --- |
| 核心载体 | HTML + CSS + GSAP/Lottie/Three.js | Phaser 3（`silly_skit`/`line_toon`）+ Canvas2D 笔触（`ink_line`）+ `screenplay.json` 编译 |
| 强项 | 动效图文、产品发布、字幕/图表/品牌片、参考复刻 | 沙雕短剧、cutout 角色、墨线生活流、表情/口型、交互式场景 |
| 角色系统 | 无内置 cutout rig / viseme；靠 HTML/素材 | `silly_skit`/`line_toon` 用 8–12 部件木偶；`ink_line` 用 `ink_figure` 骨架 + 开放双笔触；6 viseme、表情补丁 |
| 物理/游戏感 | 主要靠 GSAP；Three.js 可选 | Phaser Arcade/Matter、相机、粒子、tween |
| 渲染 | headless Chrome + FFmpeg（Node 侧） | WebView 预览 + Dart/Rust/ffmpeg 导出（计划） |
| 运行时 | Node/Chromium/FFmpeg 重依赖 | Flutter + WebView，轻依赖 |
| 适合 | 桌面端、动效/品牌视频 | 全平台、动画短片、交互原型 |

**结论**：两者不是替代关系，是“动效图文/品牌片”与“角色动画/沙雕短剧”的侧重不同。
本周期不应把 Phaser 换掉，也不应把 OpenMotion 塞进 Flutter。

## 8. 接入裁决：不引入（2026-11-21 用户裁决）

| 方案 | 做法 | 裁决 |
| --- | --- | --- |
| 只借规范 | 把 Motion.md 的“镜头/时序/可替换输入/验收证据”映射到 `screenplay.json` + DESIGN.md；借 revision/version/requestId/导出校验纪律 | ✅ **唯一允许的方向** |
| 导出适配器 | `screenplay.json` 编译为 HyperFrames HTML；调用外部 `hyperframes` CLI 渲染 | ❌ **不做**（仍属引入外部运行时/接口） |
| 内置 HyperFrames | App 内嵌 Node/Chromium/FFmpeg 或本地服务 | ❌ **不做** |
| 直接套 OpenMotion | 把 OpenMotion 当视频工作台，NaN 只做入口 | ❌ **不做** |

**唯一例外**：3D 栈继续使用 `three.js` / `three-live`（那是用户明确保留的例外，
不属于本文的外部创作工具收口范围）。视频工作台的 Phaser 3 裁决不因本文改变。

只借鉴的清单（落到我们自己的实现里）：

- Motion.md 的**规范分层**：创意规范 / 品牌数据 / 可执行工程 / 验收证据分开；
- 参考视频的**拉片维度**：钩子、镜头、节奏、转场、声音、可替换输入；
- **revision + version + requestId** 的读写纪律；
- **导出验证链**：lint → 规格 → 全解码 → 代表帧 → 哈希；
- 模板/案例的**可编辑源码 + 对照证据**组织方式。

## 9. 未验证 / 待补

- 没有在本机安装/运行 OpenMotion 或 HyperFrames，没有实测渲染质量、速度、
  内存、Windows/Linux 行为；
- 没有核验模板库中每个参考视频/字体的授权；
- 没有验证 OpenMotion 的“参考复刻”在真实沙雕/角色动画上的效果（它本身
  没有 cutout/viseme 系统，预计不适合直接做这类）；
- 没有验证 HyperFrames 0.9.77 与 OpenMotion 锁定的 0.9.7 的 ABI/格式差异；
- 没有把 OpenMotion 的 MCP 工具契约与我们的 `video_*` 工具面逐项映射。

## 10. 参考来源

- OpenMotion 仓库：<https://github.com/nexu-io/openmotion>
- OpenMotion 官网：<https://open-design.ai/motion/>
- OpenMotion `docs/motion-md.md`、`docs/hyperframes.md`、`docs/usage.md`、
  `docs/mcp-phase1-tools.md`、`docs/product/architecture.md`
- HyperFrames 仓库：<https://github.com/heygen-com/hyperframes>
- HyperFrames composition 格式：<https://github.com/heygen-com/hyperframes/blob/main/skills/hyperframes/references/format.md>
- HyperFrames npm：<https://www.npmjs.com/package/hyperframes>
- GitHub metadata：OpenMotion 14,310 stars / Apache-2.0 / v0.2.0；
  HyperFrames 87,603 stars / Apache-2.0 / v0.9.77（2026-11-21 核验）
