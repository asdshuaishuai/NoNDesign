# Awesome Opus 5.5 Videos 调研：把「代码生成视频」的提示词方法抽象成 skill

> 状态：**调研结论（2026-11-22）**，作为 `creative-workbench` skill 的输入规范。
> **只参考、不引入**：该仓库是提示词/作品索引，不是运行时；我们不复制创作者的作品、
> 视频、角色或成段提示词，只抽象结构与质量规则。
>
> 关联：[creative-workbench skill](../skills/creative-workbench/SKILL.md) ·
> [plan-creative-workbench.md](../plan-creative-workbench.md) §5 ·
> [research/3dcodeverse.md](3dcodeverse.md)（3D 线的验证式 harness）·
> [research/pixelfx.md](pixelfx.md)（视频特效子集）。

## 0. 结论先行

1. **它是什么**：`yihui-dev/awesome-opus5-5-videos` 是一个「Claude Opus 5.5 生成的
   爆款视频 + 提示词」索引。每个条目链接创作者原帖；有 418 条带 live remake；
   共 **703 条 prompt**，分 motion / 3d / explainer / interactive 四类。
   MIT，约 **16.2k stars / 1.7k forks**（2026-11-22 核验）。
2. **核心不是「提示词模板」四个字，而是「把视频当可执行程序」**：绝大多数作品要求
   模型写一个自包含 HTML/Canvas/SVG/Three.js 页面，用 `seek(t)` 或固定帧时钟驱动，
   再逐帧录制。视频是代码的产物，不是模型直接吐出的像素。
3. **高质量 prompt 的共同结构**（不是每条都有；显式标签出现 16–27 次）：
   `<inputs>` → `<direction>` → `<structure>` → `<build>` → `<gotchas>` → `<start>`。
   它把「问清输入 / 定美术方向 / 排节拍 / 写技术约束 / 列已知坑 / 先确认再开工」
   拆成可检查的六段。
4. **可量化的质量规则**：703 条中 43 条明确「one HTML file」、30 条出现 `seek(t)`、
   19 条「pure function」、17 条「no CSS transitions」/「no timers」、48 条提
   `60fps`、44 条提 `loop`、67 条提 `three.js`、43 条提 `ffmpeg`、66 条提 `beat`、
   44 条提 `bpm`。这些不是风格偏好，而是**确定性/可验收**的工程约束。
5. **我们怎么用**：把这些规则抽象成 `creative-workbench` skill 的
   **Intake → Direction → Structure → Build → Verify → Judge → Deliver** 流程；
   视频工作台用 `screenplay.json` + 固定 30fps + 风格包落地；3D 工作台用
   3dcodeverse 的 plan/check/judge 落地；`awesome` 本身不进入运行时。

## 1. 仓库事实与数据口径

| 项 | 事实 |
| --- | --- |
| 仓库 | `yihui-dev/awesome-opus5-5-videos` |
| 许可 | MIT（索引/整理；每条视频与 prompt 归创作者，转载需看原帖） |
| 内容 | 703 条 prompt（`prompts/*.md` + `data/videos.json`），418 条有 live remake |
| 分类 | motion 369 · 3d 117 · explainer 116 · interactive 101 |
| 技术标签（可多选） | canvas 267 · svg 183 · threejs 131 · shader 92 · gsap 86 · css 57 · audio 39 · playable 22 · particles 17 · pixel 15 · webgl 9 · physics 9 · ai-image 6 |
| prompt 长度 | 最短 11 字符，中位数 221，p90 1077，最长 15,583 |
| 不完整 prompt | 207 条（创作者只给了部分提示词或只描述了结果） |
| 使用方式 | 复制 Prompt 块 → 丢给 Opus 5.5 → 要求输出单 HTML → 录屏 |

**关键观察**：大部分「爆款」不是模型一次吐出视频，而是模型写了一个**可交互/可逐帧
推进的网页**，创作者再录屏或逐帧导出。`interactive` 类甚至直接是游戏/玩具；
`motion`/`3d`/`explainer` 类是「网页动画 + 录制」。这就是「代码创造世界」在视频线的
直接证据。

## 2. 高质量 prompt 的六段结构

显式使用标签的 prompt 中，出现次数：`<direction>` 27、`<inputs>` 26、`<structure>` 25、
`<build>` 22、`<gotchas>` 19、`<start>` 16。六段职责：

| 段 | 回答的问题 | 内容 |
| --- | --- | --- |
| `<inputs>` | 我还缺什么？ | 让 Agent **先问**：品牌/产品、受众、时长/画幅、配色/字体、参考片、音乐 BPM、素材、必须出现/禁止出现的东西 |
| `<direction>` | 这支片子的「一个想法」是什么？ | 美术方向、镜头语言、节奏感、唯一焦点、色彩纪律、**Banned 清单**（明确禁止模板感/彩虹渐变/无意义粒子等） |
| `<structure>` | 每一秒发生什么？ | 按 BPM/小节/秒数排事件；钩子 → 展开 → 转折 → 收束；镜头/转场/字幕/音效节点 |
| `<build>` | 用什么技术实现？ | 单文件、`seek(t)` 纯函数、无 CSS transition/timer/跨帧状态、闭式弹簧、固定 30/60fps、逐帧渲染、motion blur 子帧、先渲一帧/一拍再全量 |
| `<gotchas>` | 已知会怎么坏？ | 文字在缩放后模糊、morph 容器内文字重叠、循环首尾不一致、`will-change` 与相机缩放冲突等 |
| `<start>` | 开工前先做什么？ | 先问 inputs、先给 state/beat 表、先给一个 figure/一个镜头，得到确认再写代码 |

> 这不是唯一写法，但它是**可复用的最小骨架**：把「创作意图」与「工程约束」分开，
> 把「先问」与「先做」分开。我们的 skill 直接采用这六段，并翻译成产品里的
> `creative.spec.json` / `screenplay.json` 字段。

**反例**（同样常见）：一句话「make a modern slick video for a startup」也能出片，
但它把方向、结构、验收全部交给模型即兴，结果高度依赖模型先验，难以复现、难以改。
我们的 skill 不允许只给一句话就进入 build——必须先补 inputs/direction。

## 3. 设计思维：五条可执行原则

### 3.1 视频是代码，不是像素

- 单文件 HTML/Canvas/SVG/Three.js；无外部运行时、无素材依赖（或显式列出素材）。
- 动画是 `seek(t)` 的纯函数：给定时间 `t`，画面完全确定；没有 CSS transition、
  没有 `setTimeout`、没有跨帧可变状态。
- 弹簧用闭式阶跃响应（多次改目标 = 多个弹簧响应求和），仍是 `t` 的函数。
- 渲染器逐帧 seek + 截图；需要运动模糊时渲 4 个子帧再混合。
- 这使「改一帧」「对比参考」「重渲」都成为确定性操作。

### 3.2 先定「一个想法」，再定技术

- 每条高质量 prompt 都有 **one idea / one focal point**：一个形状 morph 成 8 个 UI
  状态；一个按钮从黑白变成唯一饱和色；一条街从下午走到夜晚。
- `Banned` 清单和 `Direction` 一样重要：明确禁止「模板感、无意义粒子、彩虹渐变、
  每个元素都在动、死时间」。
- 技术选择服从想法：UI morph 用 SVG/Canvas；3D 世界用 Three.js；像素战斗用
  Canvas 像素缓冲；不要为了炫技混三条渲染线。

### 3.3 节拍是结构，不是后期

- 44 条 prompt 提 BPM，66 条提 beat；高质量条目把「第几小节发生什么」写死。
- 先测音乐（numpy/ffmpeg）得到 beat grid，再排镜头；音效按峰值对齐。
- 渲一帧 per beat 先检查构图/可读性，再全量渲染。
- 视频工作台的 `screenplay.json` 应把 `bpm`、`beatsPerBar`、`beatOffset` 作为
  一等字段，而不是让模型在运行时猜。

### 3.4 参考片是证据，不是素材

- 高质量条目会要求：拆参考的镜头/节奏/转场/声音，做 contact sheet、逐帧差异、
  亮度/边缘统计；然后用自己的角色/品牌重建。
- 明确「references are for study only, never copy their footage/logos/characters」。
- 这与 3dcodeverse 的「reference image 是 silhouette/acceptance 证据」同构。

### 3.5 交付前必须「看过」

- 渲染 contact sheet / 逐帧条 / 代表帧；检查可读性、构图、循环、死时间、音画同步。
- 没有「渲染退出 0 就算完成」；必须有证据（帧、表、指标、judge JSON）。
- 这与 3dcodeverse 的 blind judge + deterministic gates 是同一条纪律。

## 4. 分类语法（用于自动选 skill）

| 类别 | 典型目标 | 首选技术 | 关键检查 |
| --- | --- | --- | --- |
| `motion` | UI morph、品牌片、产品 launch、音乐可视化 | SVG/Canvas/GSAP/Three.js | 节拍同步、首尾循环、字体清晰、无死时间 |
| `explainer` | 30s 讲清一个产品/流程/配方 | Canvas/SVG/GSAP | 信息层级、步骤顺序、字幕可读、时长 |
| `3d` | 3D 世界、建筑、角色、产品模型、shader | Three.js/GLSL/Blender | 几何/材质/灯光、相机、grounding、性能 |
| `interactive` | 游戏、玩具、可点击场景 | Canvas/Three.js/Phaser | 输入响应、物理、60fps、无 console error |

这张表进入 skill 的 `intake`：模型先判类别，再选 `screenplay` 还是 `3d plan`，
而不是把所有请求都塞进同一个视频模板。

## 5. 抽象成 skill：`creative-workbench`

`awesome` 的六段结构 + 五条原则，落到我们的 skill 规范（详见
[`docs/skills/creative-workbench/SKILL.md`](../skills/creative-workbench/SKILL.md)）：

1. **Intake**：先问 inputs；缺关键项不进入 build（可给默认值，但必须显式）。
2. **Direction**：写 one idea、one focal point、palette/type、banned list。
3. **Structure**：视频写 beat sheet（BPM/小节/秒）；3D 写 plan（parts/dims/
   materials/acceptance）。
4. **Build**：代码是事实源；视频 `seek(t)`；3D `plan.json` + `src/`；VFX 走
   pixelfx 过滤子集。
5. **Verify**：确定性门（视频：帧时钟/循环/无随机/无外联；3D：bbox/contact/
   grounding/placement/shader）→ 渲染证据。
6. **Judge**：fresh-context 视觉评审，只看 brief + 图；评分/缺陷/改进清单。
7. **Refine**：只改 score 列出的项；轮数由用户定；最佳轮交付。
8. **Deliver**：源文件 + 证据包 + 10 行内报告；不把成片当唯一产物。

**标准化的含义**：每个 skill 都必须有同一套 frontmatter、同一套
`spec → plan → src → artifacts → judge` 目录、同一套 gate 输出格式、同一套
judge JSON。这样视频/3D/设计可以共享一个「创作 skill 运行时」，而不是三套提示词。

## 6. 只借什么 / 不借什么

| 借 | 不借 |
| --- | --- |
| 六段 prompt 结构（inputs/direction/structure/build/gotchas/start） | 创作者的具体作品、角色、品牌、成段 prompt |
| `seek(t)` 纯函数、固定帧、闭式弹簧、首尾循环 | Skillry 的 live remake 服务/页面 |
| beat grid、BPM、逐拍检查、逐帧证据 | 任何第三方素材/音乐/字体（除非单独授权） |
| 分类语法与 one-idea 纪律 | 「爆款复制」心态：不追具体视频的皮，追可复现的方法 |
| contact sheet / frame strip / 音画同步检查 | 把 703 条 prompt 直接塞进上下文（上下文税） |

## 7. 未验证 / 待补

- 没有逐条验证 703 条 prompt 的实际产出质量；本文只做了结构与词频统计。
- 没有验证 `data/videos.json` 的分类标签与真实内容完全一致（标签是策展口径）。
- 没有测试把六段模板直接用于我们的模型时的稳定性；需要在 skill 施工时做 A/B。
- 没有核验每条 prompt 的授权（仓库 MIT 不自动等于创作者视频/素材可商用）。
- 没有把分类语法映射到 `screenplay.json` 的具体 schema；见 skill 规范 §5。

## 8. 来源

- 仓库：<https://github.com/yihui-dev/awesome-opus5-5-videos>
- `README.md`、`data/videos.json`、`prompts/*.md`（只读统计与抽样）
- GitHub metadata（stars/forks/license/updated，2026-11-22 核验）
- 相关方法：3DCodeVerse（[research/3dcodeverse.md](3dcodeverse.md)）、
  pixelfx（[research/pixelfx.md](pixelfx.md)）
