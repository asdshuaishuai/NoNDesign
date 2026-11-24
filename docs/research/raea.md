# raea 调研：3D / 短剧引擎候选（FSL 许可阻塞，只参考）

> 状态：**调研结论（2026-11-24）**，供 3D 工作台与视频短剧线评估。
> **未安装、未运行**；事实来自 `README.md`、`LICENSE`、`Cargo.toml`、`sdk/raea/`、
> `engine/cli/`、`docs/engine.md`、`apps/check/` 与 GitHub Release 元数据。
>
> 用户假设（2026-11-24）：raea 可作 **3D 适配 / 短剧制作的引擎**。本文结论：
> **技术契合度高，但当前许可证、产品形态与我们的架构都不允许直接引入**；
> 只借契约与工艺，不作为依赖、不 vendor、不捆绑。
>
> 关联：[plan-creative-workbench.md](../plan-creative-workbench.md) §4 ·
> [skills/creative-workbench/references/3d-pipeline.md](../skills/creative-workbench/references/3d-pipeline.md) §12 ·
> [research/material-painter.md](material-painter.md)（另一条材质候选） ·
> [research/3dcodeverse.md](3dcodeverse.md)（我们已采用的 3D harness）。

## 0. 结论先行

1. **它是什么**：`shinyobjectz/raea` 是「Render Anything Engine」——把视频、动效、
   3D 和游戏写成 **React + TypeScript composition**，由 **Rust + Bevy 0.20** 在
   本机 GPU 上渲染；不是浏览器套壳，也不是一个轻量 3D 库。
2. **技术契合点**：它确实覆盖我们 3D / 短剧线需要的多数能力——Bevy 3D、glTF、
   Gaussian splats、R3F/three.js 兼容、时间线、词级时间、语音驱动剪辑、
   `render/play/check/cut` 质量门、story model、agent skills。
3. **不能直接引入的三个硬理由**：
   - **许可证**：FSL-1.1-ALv2 的 *Competing Use* 条款禁止把软件用于「替代它、
     替代它的其他产品或服务、或提供相同/实质相似功能」的商业产品。我们做的
     正是 AI 原生创作工作台（含 3D/视频），按文本通常理解属于高度重叠；当前
     版本要**发布满两年**才转 Apache-2.0（0.1.9 于 2026-11-22 发布，最早
     2028-11-22）。需法务确认，不能按「开源=可嵌」处理。
   - **形态**：它是完整应用/引擎，不是一个可嵌入库。Cargo workspace **230 个
     crate**；`sdk/raea` 与 `engine/cli` 的 `package.json` 都是 `"private": true`，
     仓库内没有面向嵌入的公开库入口；对外接口是 `raea` CLI + 源码级 React/TS
     SDK。即便许可允许，也只能作为**独立进程/CLI**接，不能作为 Flutter
     进程内库。
   - **架构**：Bevy + JavaScriptCore/QuickJS + React 19 + TypeScript，和我们的
     **Flutter/Dart + three-live WebView** 是两套执行面。引入等于替换 3D/视频
     底座，而不是加一个适配器；还会把 Rust/Bun/CMake/平台库的构建与维护成本
     带进来。
4. **正确用法**：把它当**对标实现与工艺来源**——借 composition/时间/检查/
   story 的**契约形状**，不复制代码、不复制 skills 文本、不引入运行时。
   我们已选的 **three-live + 3dcodeverse** 继续作为 3D 执行面。
5. **未来重开的门槛**（四者同时满足才评估）：① 作者给出书面商业许可，或
   目标版本已过两年转 Apache-2.0；② 提供有边界的库/API（不是整仓 CLI）；
   ③ 产品裁决允许独立进程/可选外部引擎；④ 工程上只增加一个边界清晰的
   适配层。否则不进入施工。

## 1. 事实与数据

| 项 | 事实（2026-11-24 核验） |
| --- | --- |
| 仓库 | <https://github.com/shinyobjectz/raea> |
| 规模 | **4,868 stars / 392 forks**；默认分支 `main`；最近推送 2026-11-24 |
| 许可 | **FSL-1.1-ALv2**（Functional Source License 1.1, ALv2 Future License），版权 Shane Murphy |
| 最新版 | **v0.1.9**（2026-11-22）；资产含 macOS arm64、Linux x86_64、Windows x86_64 |
| 主语言 | TypeScript（产品/SDK）；Rust（引擎） |
| 引擎 | **Bevy 0.20**；自有 GPU 渲染；macOS 用 JavaScriptCore，其他平台 QuickJS |
| SDK | `raea` TypeScript SDK 0.3.0，React 19.2 + TypeScript 7.0.2；`private: true` |
| 工作区 | Cargo workspace **230 个成员 crate**；`core/ gpu/ io/ systems/ runtime/ engine/ apps/ sdk/ vendor/ tools/` |
| 构建 | Rust（pinned toolchain）+ Bun + CMake；macOS 需 Xcode CLI；Linux 需 ALSA/fontconfig/udev/xkbcommon/Vulkan/NASM |
| 产品面 | 视频、动效、3D、游戏；`raea render/play/check/cut/init/export-game/guide/context/skills` |
| 3D 面 | Bevy 相机/灯光/材质/glTF/Gaussian splats/Bevy 插件；`<R3F>` 与 `<Three program>` 兼容 three.js |
| 短剧相关面 | story model、时间线、cutout/media/words、语音驱动 `cut`、`check` P0–P3、manifest/words/taste 输入、`play` 确定性回放 |

## 2. 它到底提供什么

### 2.1 Composition 与 CLI

一个 composition 是 React 组件：`useCurrentFrame()` 取当前帧，`AbsoluteFill`
铺满画面，`Composition` 声明宽高/fps/时长，`registerRoot` 注册。CLI 直接渲染：

```text
raea render hello.tsx -o hello.mp4
raea render hello.tsx -o frame.png --frame 45
raea play game.tsx --offscreen --snapshot 1.5 a.png --seek 30 b.png --json p.json
raea check hello.mp4 --manifest render.json --words words.json -o check.json
raea cut take.mp4 "line one" "line two"
raea export-game game.tsx -o Game.app
```

这不是「一个 3D 模型导出器」，而是**代码即视频/游戏**的完整运行时：时间、输入、
音频、3D、编码、检查都在同一个 CLI 下。

### 2.2 3D

- Bevy 0.20 是唯一引擎；React/TypeScript 跑在 Bevy 内的 JS 运行时里，渲染为
  Bevy 实体与系统。
- 支持 glTF、Gaussian splats、Bevy 插件目录、材质/灯光/相机/后处理。
- `<R3F>` 直接承载 React Three Fiber 场景；`<Three program>` 承载 three.js
  页面脚本；TSL node materials 可转 WGSL 执行。
- 提供 `raea/r3f` 双向桥：raea composition 可在 R3F Canvas 里画，也可导出为
  纯 R3F 源码。

### 2.3 短剧/叙事相关

- `sdk/story` 是强类型的 story model：`world`（事实与事件）、`tellings`（观众
  看到的 beat 顺序）、`agents`（want/need/lie/mask/arc）、`values`（正负两极）、
  `turns`（价值移动步数）、`ends`（want/need/lie 的结算）、`setup/pays`。
  所有引用是 typed key，`tsc` 会拒绝未声明的 agent/fact/event。
- `sdk/video` 有 timeline、cutout、media、words、transition 等模块。
- `raea cut` 按台词切素材，返回 `cuts/words/perception/said`；`raea check`
  对成片做 P0–P3 检查：响度/真峰值、声音突然中断、静止段、暗部编码块、
  字幕越界/平台 UI 区/停留过短/对比度、字幕与词不同步、文字遮脸比例等。
- `raea play` 支持输入脚本、离屏、snapshot、seek、JSON，适合确定性回放与
  自动截图；`raea check` 在 P0/P1 时退出 1。

这些能力与我们的「30fps 整数帧 + `words.json` + 镜头表 + QA」高度同构，
但**实现栈完全不同**。

## 3. 与我们的契合/不契合

| 维度 | 契合 | 不契合 |
| --- | --- | --- |
| 3D 能力 | Bevy 3D、glTF、splats、R3F/three 兼容 | 我们已选 three-live；Bevy 是另一套渲染/ECS |
| 短剧工艺 | story model、词级时间、语音切分、P0–P3 检查 | 我们是 `screenplay.json` + 8 段脚本 + three-live；不需要整仓 |
| Agent 工作流 | skills/guide/context/check 一整套 | 我们的 `creative-workbench` 已有同构骨架 |
| 运行形态 | 本机 GPU、离线、跨平台 | 230 crate 的完整应用，不是可嵌入库 |
| 许可 | 源码可读、可学习 | FSL Competing Use；当前不能商用替代 |
| 架构 | 强类型、确定性回放 | Rust/Bevy/JS/React vs Flutter/Dart/three-live |

## 4. 为什么不能直接引入（展开）

### 4.1 许可证是硬门，不是「署名就行」

FSL 的 *Permitted Purpose* 是「任何非 Competing Use 的用途」。*Competing Use*
包括把软件提供给他人，作为商业产品或服务，且：

1. 替代该软件；
2. 替代作者用该软件提供的其他产品或服务；
3. 提供与该软件相同或实质相似的功能。

raea 自己就是「AI 帮你做视频/动效/3D/游戏」的创作工具；我们的 NaN 也是
AI 原生创作工作台（设计/3D/视频/音乐）。按文本通常理解，直接嵌入并随产品
分发属于高风险重叠。**本文不是法律意见**；真要商用集成，先让法务读
`LICENSE` 全文并与作者确认书面许可。

两年转 Apache-2.0 是**按版本**计算的：0.1.9 于 2026-11-22 发布，最早
2028-11-22 才可按 Apache-2.0 使用该版本；不等于现在可以用 main 的最新代码。

### 4.2 它不是库，是完整应用

- `sdk/raea/package.json`：`"private": true`，`"main": "src/index.tsx"`，
  依赖 React 19、mediabunny；仓库内没有公开 npm 发布入口。
- `engine/cli/package.json`：`"private": true`，`@raea/cli`，入口 `src/index.ts`。
- 没有面向嵌入的稳定 C ABI/库 crate；对外是 CLI + 源码级 TS SDK。
- 工作区 230 个 crate，含自有 GPU、编解码、JS 引擎、Bevy 插件、ML/ONNX、
  ffmpeg 封装、平台适配；构建需要 Rust/Bun/CMake 和一堆系统库。

这意味着「引入 raea」不是加一个 dependency，而是把它的整个运行时、构建链
和升级节奏搬进来；和我们的「纯 Dart 核心、无 Python 服务、3D 走 three-live」
边界直接冲突。

### 4.3 产品边界

raea 自带 agent、studio、timeline、review、Index、skills；它本身就是一个
创作工作台。我们引入它会把「我们是自己的产品」变成「我们在别人的工作台
上套壳」——这正是 2026-11-21 用户裁决要避免的。即使只引入引擎，也会带来
两套 agent/工作流/质量门的重复。

## 5. 可以借什么（只借契约，不抄代码）

1. **Composition 的「帧函数」形状**：`frame -> 画面`，时间是一等输入。
   我们的视频运行时已经是 `stateAt(frame)`，不需要引入 React；但可以继续
   坚持「无隐式时钟、seek=reset+replay」。
2. **词级时间锚点**：raea 的 `word()`/`findPhrase()` 让 cue 跟着语音走。
   我们的 `words.json` 已有词级 start/end；可把「cue 必须挂在词上，而不是
   绝对秒」写进 `story-short.md` 的验收。
3. **`check` 的 P0–P3 分级与输入面**：成片文件 + render manifest + words +
   perception + taste。我们的 QA 目前是黑/白/冻结/pops/响度/接触表；可增加
   「字幕越界/平台安全区/停留时长/字幕-词不同步/遮脸比例」这些可测量项，
   仍用 Dart/JS 实现，不引 raea。
4. **`cut` 的语音驱动剪辑**：按台词切素材、返回词级时间与感知结果。可作为
   视频工作台未来的「台词对齐剪辑」功能参考，不引其实现。
5. **story model 的 typed key 思路**：world/telling/beat 分层、value turns、
   setup/payoff。我们的 `story-short.md` 是 8 段轻量脚本；不需要完整 story
   engine，但可借「每个 beat 必须有 reveal/feel/setup-payoff」的检查项。
6. **guide/context/skills 的交付纪律**：craft guide 与代码同源、`context`
   告诉 agent 先读什么。我们的 `creative-workbench` 已经在做同构的事；可借
   「guide 必须能被 `context` 验证」的思路，不复制文本。
7. **3D 的 R3F/three 兼容面**：它证明 three.js 生态仍是 agent 最熟悉的 3D
   语言；我们的 three-live 路线不需要改。

## 6. 不引入清单

- 不 vendor 任何 raea 代码、crate、TS SDK、skills、craft guides、示例资产。
- 不把 `raea` CLI 作为产品依赖、不内置进程、不随包分发、不设导出适配器。
- 不引入 Bevy、JavaScriptCore/QuickJS、React、Bun、CMake 到产品运行时。
- 不复制其 story model / check 规则文本 / 提示词 / 参考帧 / 角色 / 镜头。
- 不把「FSL 两年后转 Apache」当作当前版本的商用依据。

## 7. 如果未来要重开

按顺序过四道门：

1. **许可**：作者书面商业许可，或目标版本已满两年转 Apache-2.0；法务确认。
2. **形态**：有稳定的库/API 或受支持的独立进程协议；不是只能整仓构建。
3. **产品**：用户裁决允许「可选外部引擎」或独立 companion，不破坏纯 Dart
   核心与 three-live 主路径。
4. **工程**：能证明只增加一个边界清晰的适配层，而不是替换 3D/视频底座；
   有性能、包体、升级、崩溃隔离的实测。

四道门未过之前，raea 只停留在 `docs/research/`。

## 8. 未验证 / 待补

- 未安装/运行 raea；能力来自 README、源码目录、docs 与 release 元数据，
  没有实测渲染质量、性能、包体、跨平台稳定性。
- 未做 FSL 的正式法务评估；「是否构成 Competing Use」需律师判断。
- 未验证 `raea check` 的阈值在我们的编码器/色彩管理下是否可直接复用；
  本文只借检查项，不借数值。
- 未验证 raea 的 story model 对中文短剧的适配；我们的 8 段脚本仍是主路径。
- 未评估 230 crate 工作区的实际构建时间/产物体积；仅从 manifest 判断「重」。

## 9. 来源

- 仓库：<https://github.com/shinyobjectz/raea>
- `README.md`、`LICENSE`、`Cargo.toml`、`docs/engine.md`、`docs/README.md`
- `sdk/raea/README.md`、`sdk/raea/package.json`、`sdk/r3f/README.md`
- `sdk/story/src/model.ts`、`sdk/video/src/`
- `engine/cli/package.json`、`engine/cli/src/cli.rs`、`engine/cli/src/usage.rs`
- `apps/check/src/lib.rs`、`apps/check/src/{sound,picture,defects}.rs`
- GitHub Release `v0.1.9` 资产与仓库元数据（2026-11-24 核验）
