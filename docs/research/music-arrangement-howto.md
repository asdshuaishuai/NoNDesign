# 编曲工作台：可施工技术调研（2026-11-20）

> 状态：**调研结论，供施工与方案回填**。对应愿景 [vision.md](../vision.md)「代码创造世界」；
> 模块方案 [plan-music-module.md](../plan-music-module.md)。本文回答「怎么做」，不写市场分析。
> 证据标记：【事实】有官方文档/仓库/许可证来源；【推断】工程判断，需原型验证。

## 0. 结论先行

1. **事实源**：`score.json` 继续做唯一事实源；MusicXML / MEI / ABC / MIDI 只做导入导出适配器，绝不进入编辑器内存模型。
2. **时间模型**：乐谱层存**有理数时值**（全音符 = 1）与显式连音（tuplet）元数据；播放层编译成**整数 tick**（建议 `ppq = 3840`，可整除 2/3/4/5/8/16；v1 不做七连音）。不要用浮点拍、不要用 `double` 累加。
3. **编辑器**：纯 Dart 布局 + `CustomPainter` 自绘，SMuFL 度量 + Bravura 字体；WebView 只做「只读 MusicXML/MEI 预览」副路径，不进入主编辑链。
4. **播放**：WebView 内自写 lookahead 调度器（25 ms tick / 100 ms ahead，后台 2 s），`AudioContext.currentTime` 是唯一时钟；六种代码合成音色 + 鼓组，不引大采样库。
5. **编曲生成**：模板 + 功能和声语法 + DP/Viterbi 声部进行 + 种子 PRNG；输出可编辑音符 + `provenance`，validator 是硬门。不用端到端黑盒模型。
6. **验收**：纯函数单测 → 布局 JSON 快照 → 少量 golden → 交互/属性测试；自动规则校验 + 盲听 A/B。

## 1. 数据格式与时间模型

### 1.1 各格式的定位【事实】

| 格式 | 定位 | 能否做事实源 | 本项目角色 |
| --- | --- | --- | --- |
| **MusicXML 4.0** | 交换 + 归档标准（W3C CG），partwise/timewise 双根、`backup/forward` 时间游标、`<chord/>`、`<tie>` start/stop、`<beam>` 逐 note 标记 | 否：为交换保留大量呈现冗余，round-trip 易漂移 | 导入/导出（必须） |
| **MEI 5.1** | 学术编码框架，逻辑/视觉/手势/分析四域；记谱软件采用度低 | 否：语义过富、Dart 生态空白 | 可选导入/导出 |
| **ABC 2.1** | 文本记谱，民谣/单旋律强；多声部行为仍 VOLATILE | 否：表达力不足 | 简单导入 |
| **MIDI 1.0/2.0** | 演奏事件，不含拼写/符杠/连线/布局 | 否 | 播放/导出 |
| **MNX 1.0 draft** | JSON 原生乐谱格式，强调「只有一种写法」；仍 draft | 候选，不建议直接依赖 | 设计参考 / 未来导出 |
| **自定义 score.json** | 产品定义，语义与布局分离 | **是** | 唯一事实源 |

来源：MusicXML 4.0（https://www.w3.org/2021/06/musicxml40/）、MIDI-compatible part（https://www.w3.org/2021/06/musicxml40/tutorial/midi-compatible-part/）、MEI（https://music-encoding.org/guidelines/v5/content/introduction.html）、ABC 2.1（https://abcnotation.com/wiki/abc:standard:v2.1）、MNX（https://mnx.formats.music/docs/）。

### 1.2 score.json 设计原则

1. **音乐语义与布局分离**：只存音高、时值、声部、关系、用户覆盖；不存计算出的 x/y。
2. **有理数时值**：`dur: {num, den}`（全音符 = 1），例如四分 = `{num:1, den:4}`；附点 = 乘 3/2；连音用 `tuplet: {n, in, group}` 显式表达。
3. **关系对象**：`Beam{id, events[]}`、`Tie{from, to, notes[]}`、`Slur{from, to}`；不要在单个 note 上写 `beam=true` / `tie=start`（MusicXML 的冗余是反例）。
4. **音高拼写与 MIDI 分离**：`{step:"C", alter:1, octave:4}`；播放时再算 MIDI，保留升降号语义。
5. **稳定 ID**：事件、关系、小节都有 ID；编辑和撤销按 ID，不按数组下标。
6. **版本与迁移**：`schemaVersion` 整数；读 N-1 写 N；固定 fixture；未知字段保留。
7. **校验不只 JSON Schema**：小节容量、声部一致性、tie 目标同音高、beam 同声部、slur 端点存在、反复结构合法。

### 1.3 时间模型：有理数 → 整数 tick

```text
score.json（有理数）
   │  编译期（纯函数）
   ▼
PlayPlan（整数 tick，ppq=3840；tempoMap；events）
   │  Web Audio lookahead
   ▼
AudioContext.currentTime
```

- `ppq = 3840`：四分音符 3840 tick；三连音 1280、五连音 768、七连音 548.57（**v1 拒绝**，或改用 26880 的更高 ppq）。
- 所有 `start/dur` 编译成 `int tick`；运行时不再出现 `double` 拍点。
- tempo map 用分段常数 BPM；渐快/渐慢拆成小段，不做连续插值。
- 秒只在播放/导出时派生：`sec = tick * 60 / (bpm * ppq)`。

【推断】这比「score.json 直接存 tick」多一层编译，但换来两件事：编辑器可以精确表达附点/连音/跨小节，播放器可以逐 tick 断言。两层都是纯函数，可测试。

## 2. 五线谱渲染与编辑器

### 2.1 方案选择：CustomPainter 主路径【推断】

| 方案 | 确定性 | 零端口 | 编辑可控 | 排版质量 | 工期 | 结论 |
| --- | --- | --- | --- | --- | --- | --- |
| **纯 Dart 布局 + CustomPainter** | 高 | 是 | 高 | 中（子集） | 高 | **主方案** |
| WebView + OSMD/VexFlow | 低–中 | 难（本地资源常需 localhost） | 低（状态分裂） | 中–高 | 低 | 只读预览 |
| WebView + Verovio | 中 | 难 | 低 | 高 | 低 | 只读/打印对照（LGPL 合规） |
| 原生纹理（Verovio/FFI） | 中–高 | 是 | 低 | 高 | 最高 | 出版级才考虑 |

理由：零端口、离线、确定性、Linux 覆盖、命中测试与模型紧耦合；WebView 的字体/资源/引擎差异会持续制造例外（Flutter 本地资源 issue https://github.com/flutter/flutter/issues/66932）。

### 2.2 SMuFL / Bravura 度量【事实】

- SMuFL 1.4：1 em = 4 staff spaces；1000 upm 时 1 space = 250 units；字形原点在五线谱底线中点。
- `engravingDefaults`：`staffLineThickness`、`stemThickness`、`beamThickness`（示例 0.5）、`beamSpacing`（示例 0.25）、`legerLineExtension` 等，单位 staff spaces。
- `glyphsWithAnchors`：`stemUpSE` / `stemDownNW` 连接符头与符干；`stemUpNW` / `stemDownSW` 决定旗长；`cutOut*` 用于升降号互锁。
- `glyphBBoxes`：碰撞与间距。
- Bravura 许可：SIL OFL 1.1（可嵌入商业软件；保留 OFL；衍生不能用保留名 Bravura；不单独售卖字体）。

来源：SMuFL metrics/anchors/engravingDefaults（https://smufl.formats.music/latest/）、Bravura（https://github.com/steinbergmedia/bravura）、Bravura.json（https://github.com/steinbergmedia/bravura/blob/master/redist/Bravura.json）、OFL（https://raw.githubusercontent.com/steinbergmedia/bravura/master/LICENSE.txt）。

### 2.3 布局流水线（纯函数）

```text
ScoreDocument
  → normalize（声部/和弦/tie/beam/slur/accidental 状态）
  → horizontal spacing（每事件理想宽度）
  → line breaking（system 划分 + justification）
  → vertical layout（staff 间距、歌词/力度避让）
  → element placement（stem/beam/slur/tie/dot/accidental）
  → display list（glyph runs + lines + curves + hit regions）
  → paint / SVG / PDF
```

每个阶段输入不变则输出字节级稳定；缓存键 = `documentRevision + layoutOptions + width + staffSpace`。

**难点与做法【推断】**：
- 水平间距：`minWidth + k * duration^α`（α≈0.5–0.7）；换行 MVP 用贪心+回看 2–3 小节，进阶 DP 最小化 `stretch² + breakPenalty`。
- 符杠：按拍号+手动覆盖分组；stem 方向按离中线最远的音；斜率 clamp；beam 落在合法线位；主/次 beam 厚度用 `engravingDefaults`；跨小节拆分续段。
- 连音线：三次 Bézier；端点贴符头边缘；按「碰撞 + 偏离 + 曲率」评分选候选（LilyPond 的 ugliness score 思路）。
- 延音线：跨强拍拆成两个 note + tie；和弦逐音高配对；跨 system 画续段；播放合并时值。
- 附点：放符头右侧；落线则移到相邻 space；和弦多附点堆叠避碰。
- 升降号：按 `(staffId, octave, step)` 维护小节状态；显示判定对比 key signature；和弦 accidental 排成列，用 bbox/cutOut 算列宽。
- 和弦：同起同值同声部共享 stem；二度 cluster 符头水平错开；stem 连最远符头。
- 跨小节：模型层用关系对象；布局在 barline/system break 切分；播放合并 tie。

LilyPond 的自动排版本质是「多候选 + 丑度评分」，不是单一规则（https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving）；MVP 不要追求出版级。

### 2.4 编辑器交互

| 操作 | 建议 |
| --- | --- |
| 进入输入 | `N` 进入，`Esc` 退出；显示 ghost note |
| 时值 | `1–9`（选一套并标注；MuseScore 与 Flat 顺序相反） |
| 音高 | `A–G`；上下箭头半音；`Ctrl/Cmd+↑↓` 八度 |
| 和弦 | `Shift + 字母` 叠加 |
| 休止 | `0` |
| 附点 | `.` |
| 连音线 | `T`（可重映射） |
| 变音 | `-` 降、`+` 升、`=` 还原 |
| 删除 | `Delete` 删元素；`Backspace` 删除并左移 |
| 选择 | 单击/Shift 扩展/框选；选择模型用 `Set<EventId>` |
| 撤销 | 命令栈（Insert/Delete/SetPitch/SetDuration/Move/AddMeasure/RemoveMeasure/ToggleTie/SetBeam）；拖拽合并为一个 transaction；不写入 score.json |

参考：MuseScore（https://handbook.musescore.org/basics/entering-notes-and-rests）、Flat（https://help.flat.io/en/music-notation-software/keyboard-shortcuts）、Noteflight（http://assets1.noteflight.com/docs/noteflight-keys.pdf）。

### 2.5 命中测试与缩放【推断】

- 布局产出 `HitRegion{id, kind, bounds, zIndex, eventId}`；粗筛 bounds，再按类型精判。
- 容差：`tolY = max(0.45 * space, 5 / zoom)`，`tolX = max(0.75 * space, 6 / zoom)`；50% 缩放下屏幕容差至少 5–6 px。
- 空白点击：y 量化到最近线/间，x 量化到最近节拍/事件，显示 ghost note。
- 重叠：notehead > accidental > stem > beam > measure；重复点击循环选择。
- 缩放改变 `staffSpace` 重新布局，不用位图缩放；编辑下限 75%，50% 只读总览。
- 高 DPI：坐标逻辑 px，线条逻辑宽度；不要硬编码 1x/2x；2x/3x golden。

### 2.6 测试策略

1. **纯函数单测**：音高→staff position、MIDI、调号/临时记号、Rational 运算、BeamGrouper、LineBreaker、HitTester、PlaybackTimeline。
2. **布局 JSON 快照**：element id + 圆整坐标 + glyph id；CI 高频跑。
3. **Golden**：固定 Bravura、surface、DPR；只覆盖 8–10 个 canonical 用例；Flutter 默认 Ahem 字体，必须显式加载。
4. **交互测试**：按布局结果算 notehead 中心 `tapAt`；拖拽断言命令栈。
5. **属性测试**：随机合法乐谱；断言 x 单调、宽度非负、每事件有 hit region、beam 同声部、tie 同音高、无 NaN。
6. **Round-trip**：MusicXML → score.json → MusicXML；MIDI 导出用独立 parser 验证。

## 3. 播放与合成

### 3.1 时钟与调度【事实】

- `AudioContext.currentTime` 是唯一时钟；默认 render quantum 128 帧（44.1 kHz ≈ 2.9 ms）。
- lookahead：`setInterval` 25 ms，提前 100 ms 把事件排到音频时钟；不要在定时器回调里直接 `start()`。
- 后台节流：Chrome 不可见 >5 分钟进入 intensive（每分钟一次）；隐藏时把 ahead 提到 2 s，长休止预排。
- 暂停/seek：每个 voice 持有 gain/oscillator；`cancelScheduledValues` + 短淡出 + `stop`；`generation` 代际号丢弃旧调度。

来源：Web Audio（https://www.w3.org/TR/webaudio/）、Chris Wilson scheduling（https://web.dev/articles/audio-scheduling）、MDN setTimeout 节流（https://developer.mozilla.org/en-US/docs/Web/API/Window/setTimeout）、Chrome 88 throttling（https://developer.chrome.com/blog/timer-throttling-in-chrome-88）。

### 3.2 六个音色 + 鼓组（可调配方）【配方】

| 音色 | 核心 | 关键参数 |
| --- | --- | --- |
| piano | 3 层 PeriodicWave（body 1/n^1.3、bright 1/n^0.7、octave 正弦）+ 击槌噪声 | LP `1200+6000*vel/127 → 1.2k` 1.2 s；A 3 ms/D 1.4 s/S 0/R 250 ms；24 复音 |
| strings | 2 saw ±7 cents + triangle 低八度 | LP 3.5 kHz Q 0.7；A 250 ms/D 400 ms/S 0.75/R 700 ms；颤音 5.2 Hz/4 cents；chorus 12/19 ms；16 复音 |
| bass | sine + triangle + saw → LP 包络 | `2000→250 Hz` 120 ms；A 3 ms/D 150 ms/S 0.6/R 80 ms；3 复音 |
| bell | 2-op FM 1:1.41 + 1:3.5 + 击打噪声 | index `3.0→0.05` 1.5 s；carrier 衰减 2.5 s；8 复音 |
| organ | 9 sine（0.5,1.5,1,2,3,4,5,6,8 × f0） | 拉杆 `(level/8)^1.5*0.08`；click 8 ms；颤音 6.2 Hz/3 cents；12 复音 |
| pluck | 离线预渲染 Karplus-Strong 缓冲 | 2 s、`g=0.996`、LRU 24 音；8 复音 |
| drums | 噪声 + 扫频正弦 | kick 150→45 Hz 60 ms；snare 噪声 HP 1.2k + 185/330 Hz；hat HP 7k；clap 4 burst；crash 1.2 s |

- 所有振荡器/缓冲必须有 `stop` 路径；`exponentialRampToValueAtTime` 目标不能为 0。
- 混响：噪声 × 指数衰减造 IR（rt60 1.2–2.5 s），共享 Convolver；不要每 voice 一个。
- 总线：voice 峰值 0.2–0.3 → 乐器总线 → master 0.7 → limiter（−3 dB）；目标峰值 ≤ −1 dBFS。

来源：Web Audio 规范、Sound on Sound 弦乐/铃配方、808 底鼓、合成器鼓配方（见 §7）。

### 3.3 Tone.js / 采样 / SoundFont 取舍【推断】

- Tone.js MIT、约 76.6 KB gzip；Transport 默认 PPQ 192、lookAhead 0.1 s；`PolySynth` 超限**丢音**而非抢占。适合快速原型，不适合「和弦不能缺音」的编曲工作台。
- 采样：几百 KB 只够 20–30 个短单音；钢琴要 3 力度层 × 每 3 半音，远超预算。MVP 不引采样。
- SoundFont 备选：SpessaSynth（Apache-2.0）+ FluidR3Mono（MIT，需保留声明）可做桌面高保真试听；**不要打包 GeneralUser GS**（样本来源灰区）。
- 原生备选：`flutter_soloud`（MIT）+ `soundfont_kit`（MIT）用于 WebView 不可用时的播放后端；`PlaybackEngine` 接口隔离。

## 4. 编曲生成（symbolic）

### 4.1 原则

1. 生成器是纯函数：`generate(seed, params, input) -> Score`；同输入必同输出。
2. 输出可编辑音符，不是音频；每条轨可锁定/重生成。
3. 带 `provenance`：seed、风格、模板、生成器版本、参数、锁定轨。
4. 必须过 validator 才提交；失败 → 修复/换种子，不静默。
5. 不用端到端黑盒模型；模型只能做「草稿灵感」，输出必须回写 score.json 并过门。

### 4.2 和弦进行：模板 + 功能语法 + 终止式

- 模板：`I–V–vi–IV`（流行）、`I–IV–V–I`（民谣）、`i–VI–III–VII`（电子）、`I–vi–IV–V`（管弦）。
- 功能语法：`I→IV/V/vi/ii`、`ii→V/IV`、`IV→I/V/ii`、`V→I/vi`、`vi→IV/V/ii`。权重表存 JSON。
- 终止式：乐句末 `V–I`/`IV–I`/`V–vi`；最后完全终止。
- 所有随机走种子 PRNG；用户锁定的和弦优先。

### 4.3 旋律配和声：DP/Viterbi

- 状态：候选和弦 + 转位 + voicing。
- 转移代价：声部移动距离、共同音保持、反向进行奖励；平行五/八、声部交叉/重叠、音域越界为硬约束；重复三音/七音重罚。
- 发射代价：旋律音与和弦音关系；强拍非和弦音重罚。
- 复杂度：16 小节 × 8 和弦 × 20 voicing ≈ 5 万次转移，Dart 毫秒级。

### 4.4 四部写作规则【事实】

- 平行纯五/纯八禁止（同向与反向都算）；减五→纯五禁止（bass 与上声部）；隐藏五/八只在外声部且女高音跳进 ≥3 半音时判错。
- 声部交叉/重叠避免；S–A、A–T 间距 ≤ 八度；三和弦重复根音，不重复三音/七音；各声部在音域内。
- music21 的 `VoiceLeadingQuartet` 是参考实现（parallelFifth 对反向也返回 true）。

来源：https://intmus.github.io/inttheory18-19/10-intro-part-writing/b1-part-writing-errors.html 、https://www.music21.org/music21docs/moduleReference/moduleVoiceLeading.html 。

### 4.5 伴奏型与风格预设

- 网格模板：16 分音符；每条 pattern = `(step, pitchClass, dur, velocity)`。
- 声部：bass（根/五、八度脉冲）、keys（块和弦/琶音）、pad（长音）、drums（pop/folk/electronic/orchestral）。
- 风格预设是 JSON，不是代码分支：tempo range、和弦词汇、进行模板、终止式、配器、pattern、mix。
- 4 个 MVP 预设：流行、民谣、电子、管弦。

### 4.6 校验器（硬门）

| 类别 | 检查 | 级别 |
| --- | --- | --- |
| 结构 | schema、必填、类型 | 硬 |
| 时间 | start/dur ≥ 0、不重叠、跨小节 tie | 硬 |
| 音域 | 每乐器/声部范围 | 硬 |
| 和声 | 平行五/八、隐藏五/八、减五→纯五 | 硬 |
| 声部 | 交叉、重叠、S–A/A–T 间距、重复三音/七音 | 硬 |
| 节奏 | 网格、单声部重叠、tie 合法性 | 硬 |
| 旋律 | 大跳后反向级进、连续同向 | 软 |
| 混音 | 同时 voice 预算、峰值余量 | 软 |

生成失败 → 本地修复（改内声部/换转位/八度移位）→ 最多 N 次换种子 → 仍失败就诚实报错，不输出坏谱。

### 4.7 算法作曲的边界

- 可离线、可控：规则、DP、马尔可夫、遗传算法、约束编程。
- 只当灵感/桌面实验：Music Transformer、NotaGen（约 8 GB GPU）、Magenta（主仓库已归档）、MuseNet（闭源）、MusicGen（音频且权重 CC-BY-NC）。
- 任何模型输出：符号格式 → 解析 → 结构校验 → 声部校验 → 标记「AI 草稿」；不得绕过 validator。

## 5. 测试、验收与性能

- 单测：validator 每条规则正/反例；平行五/八构造 C–G→D–A、C–G→G–C、C–F→B–E（减五放行）。
- 属性：同 seed 两次生成字节相同；通过 validator 的谱编译 PlayPlan 不抛异常、事件时间单调；音符在音域内。
- 黄金：`pop_ballad_8bar.json` 等生成结果；改生成器后 diff 审阅。
- A/B：离线渲染 WAV，统一到 −16 LUFS、true peak ≤ −1 dBTP；随机化顺序、盲测；ABX/偏好 AB。
- 性能目标【推断】：100 小节滚动 60fps；编辑响应 <50 ms；validator 16 小节 <20 ms；生成 16 小节 <100 ms；连续播放 10 分钟调度偏差 <5 ms；暂停/seek 无残留音。

## 6. 施工顺序（MVP）

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| M0 | WebView/原生音频桥 + 单音 + 播放/暂停 | 用户手势可发声；暂停无残留 |
| M1 | 调度器 + tempo map + 六音色 + 鼓组 | 16 小节 demo 可播、无削波 |
| M2 | 和弦/进行/DP 配和声 + validator | 8 小节流行进行 0 硬错 |
| M3 | 风格预设 + 伴奏型 + 编辑/重生成 | 4 风格各 1 demo；seed 可复现 |
| M4 | 离线渲染 WAV + A/B + 性能调优 | 3 分钟导出；盲测流程可跑 |

编辑器可与 M1–M3 并行：先做只读谱面（布局+渲染），再做输入/选择/撤销，最后接播放头。

## 7. 许可证与风险

| 依赖/资产 | 许可 | 结论 |
| --- | --- | --- |
| Bravura / SMuFL | SIL OFL 1.1 | 可嵌入；保留 OFL；不单独售卖字体 |
| MusicXML / MEI / ABC | 规范本身开放 | 解析器自写或用 MIT/BSD 库 |
| Tone.js | MIT | 可选，不默认 |
| smplr / soundfont-player | MIT | 可选；样本需镜像/授权 |
| SpessaSynth | Apache-2.0 | 桌面备选 |
| FluidR3Mono | MIT（MuseScore 声明） | 可用；保留声明；注意与 FluidR3_GM 的 CC-BY 说法冲突 |
| GeneralUser GS | 自定义 v2.0，样本来源灰区 | **不打包** |
| FluidSynth | LGPL-2.1 | 不做 |
| Verovio | LGPL-3.0（仓库亦列 GPL） | 只读/离线边界，需合规评估 |
| LilyPond | GPL-3.0 | 不进运行时 |
| MusicGen 权重 | CC-BY-NC 4.0 | 商业产品禁用 |

**主要风险**：排版范围失控（先做子集）、WebView 本地资源/零端口（不放进主编辑链）、Web Audio 在纯 Flutter 不可用（PlaybackEngine 抽象 + 原生备选）、第三方 0.x 包（接口隔离 + spike）、许可证（运行时只用 MIT/BSD/Apache/OFL）。

## 8. 不要做

1. 不要用 MusicXML/MEI/MIDI 做事实源；不要存计算出的 x/y。
2. 不要用 double 存音乐时间；不要用浮点拍累加。
3. 不要第一版做出版级 engraving；不要全量 MusicXML。
4. 不要把 WebView 放进主编辑路径；不要用 localhost 解决本地资源。
5. 不要依赖系统字体；固定 Bravura 版本 + metadata。
6. 不要每音符一个 widget；不要 `saveLayer` 滥用。
7. 不要用 Tone.js 的 `PolySynth` 当和弦引擎（丢音）。
8. 不要打包 GeneralUser GS / FluidSynth；不要用 CC-BY-NC 模型权重做商业功能。
9. 不要用黑盒音频生成替代可编辑编曲；所有生成必须可拆轨、可复现、过 validator。
10. 不要在 `setTimeout` 回调里直接 `start()`；不要用 `exponentialRampToValueAtTime(0)`。

## 9. 主要来源

- MusicXML：https://www.w3.org/2021/06/musicxml40/ · https://www.w3.org/2021/06/musicxml40/tutorial/midi-compatible-part/
- MNX：https://mnx.formats.music/docs/ · https://mnx.formats.music/docs/comparisons/musicxml/
- MEI：https://music-encoding.org/guidelines/v5/content/introduction.html
- ABC：https://abcnotation.com/wiki/abc:standard:v2.1
- SMuFL/Bravura：https://smufl.formats.music/latest/ · https://github.com/steinbergmedia/bravura
- LilyPond Essay：https://lilypond.org/doc/v2.24/Documentation/essay/automated-engraving
- Verovio：https://book.verovio.org/advanced-topics/layout-options.html
- OSMD：https://github.com/opensheetmusicdisplay/opensheetmusicdisplay
- VexFlow：https://github.com/vexflow/vexflow
- MuseScore/Flat/Noteflight 快捷键：见 §2.4
- Web Audio：https://www.w3.org/TR/webaudio/ · https://web.dev/articles/audio-scheduling
- Tone.js：https://github.com/Tonejs/Tone.js
- SpessaSynth：https://github.com/spessasus/spessasynth_lib
- smplr：https://github.com/danigb/smplr
- GeneralUser GS 许可：https://github.com/ROCKNIX/generaluser-gs/blob/main/LICENSE.txt
- FluidR3Mono 许可：https://github.com/musescore/MuseScore/blob/master/share/sound/FluidR3Mono_License.md
- 四部写作规则：https://intmus.github.io/inttheory18-19/10-intro-part-writing/b1-part-writing-errors.html
- music21 voice leading：https://www.music21.org/music21docs/moduleReference/moduleVoiceLeading.html
- 算法作曲综述：https://arxiv.org/abs/1402.0585
- NotaGen：https://github.com/ElectricAlexis/NotaGen
- Magenta：https://github.com/magenta/magenta
- MusicGen：https://github.com/facebookresearch/audiocraft
- Flutter CustomPainter：https://api.flutter.dev/flutter/rendering/CustomPainter-class.html
- Flutter golden：https://api.flutter.dev/flutter/flutter_test/matchesGoldenFile.html
