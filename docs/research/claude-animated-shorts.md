# Claude Animated Shorts 调研：2D 角色 + 3D 世界的动画短剧流水线

> 状态：**调研结论（2026-11-24）**，供视频工作台的动画短剧线参考。
> **只参考、不引入**：不引入 Remotion / React / Node / Chromium 运行时，也不复制
> 其参考素材、角色、脚本或镜头。事实来自 README、`SKILL.md`、`references/`、
> `templates/` 源码与 Remotion/Three.js 官方文档的只读检查；**未安装、未运行**。
>
> 关联：[video-pipeline.md](../skills/creative-workbench/references/video-pipeline.md) ·
> [story-short.md](../skills/creative-workbench/references/story-short.md) ·
> [plan-creative-workbench.md](../plan-creative-workbench.md) §5 ·
> [research/video-animation-howto.md](video-animation-howto.md)。

## 0. 结论先行

1. **它是什么**：`mromidev/claude-animated-shorts` 是一个 Claude skill，用
   **three.js + Remotion** 在本地渲染 55–70 秒竖屏动画短剧：2D 扁平卡通角色站在
   彩色 3D 手绘世界里，黑墨描边、景深、滑翔相机、进行曲配乐与合成音效；
   不使用 AI 视频生成器。MIT，约 **4.7k stars / 983 forks**（2026-11-24 核验），
   示例《The Bridge That Fell for a Song》67 秒。
2. **它真正的价值不是 Remotion，而是「动画短剧的完整工艺链」**：
   事实选题 → 8 段式脚本 → 配音/词级时间 → 镜头表 → 世界/角色/后期 → 声音 →
   静帧 look-match → 逐帧 QA → 2K 交付。每一步都有可检查的产物。
3. **它和我们的 `screenplay.json` + 30fps 确定性路线高度同构**：
   都是「代码是事实源、镜头按帧编号、声音对齐词级时间、渲染前先看静帧/接触表」。
   我们可以把它的**脚本公式、镜头语法、look 数值、QA 逻辑**吸收进
   `creative-workbench`，但不需要 Remotion。
4. **建议新增候选风格 `toon_3d`（2D 角色 + 3D 世界）**：与 `silly_skit`（沙雕）、
   `line_toon`（美式硬线）、`ink_line`（墨线手绘）并列；本轮先登记为
   **调研候选、待裁决**，不直接改风格数量。执行面用我们已有的 **three-live**，
   角色用 billboard/Canvas2D 贴片，后期用 three.js 后处理链，渲染走我们的
   固定 30fps/逐帧导出。
5. **不引入**：Remotion（自有许可，非 MIT）、`@remotion/three`、React/Node/
   Chromium/ffmpeg 运行时、1.3GB 参考资产、作者的参考片/角色/脚本/镜头。
   three.js 本身已是我们的 3D 例外，继续用。

## 1. 仓库事实

| 项 | 事实 |
| --- | --- |
| 仓库 | `mromidev/claude-animated-shorts` |
| 许可 | 代码与文档 **MIT**；`references/` 的参考帧/视频是**私有风格研究素材**，不可上传/发布/再分发 |
| 语言 | TypeScript（Remotion/React/three.js 工程） |
| 社区 | 约 4,725 stars / 983 forks（2026-11-24） |
| 形态 | Claude skill + 完整 Remotion 工程模板 + 音频合成脚本 + QA 脚本 + 20 条参考短片的测量报告 |
| 依赖 | Remotion + `@remotion/three` + Node + Python 3 + ffmpeg；`public/` 约 1.3GB |
| 输出 | 竖屏 1080×1920 30fps，55–70s；最终 2K 1440×2560（`--scale 1.3333`） |
| 示例 | 《The Bridge That Fell for a Song》，67s，1831 Broughton 桥 |

目录：

```
SKILL.md                       完整流水线、规则、修复与最终 look 数值
templates/bridge/              world/cast/ink/lensblur/grade/story 源码
templates/audio/               SFX/进行曲/混音/ducking/响度
templates/scripts/             静帧、side-by-side、shot merge、逐帧 QA
references/STYLE_BIBLE.md      20 条参考短片的脚本/视觉公式
references/reports/            7 份测量报告（motion/depth/textures/characters/lighting/outlines/grade）
references/frames/             38 张 540×960 参考帧
references/sheets/             20 张接触表（每张 60 帧，共 1200 帧）
```

**许可提醒**：MIT 只覆盖代码/文档；参考视频、参考帧、角色、脚本、配音、音乐
不能因为仓库 MIT 就当作可商用素材。作者明确要求「故事/角色/声音必须是自己的，
参考只用于风格研究」。

## 2. 完整流水线（11 步）

| 步 | 产物 | 关键纪律 |
| --- | --- | --- |
| 1. Topic & facts | `SCRIPT.md` 顶部：事实 + 来源 | 一个**有物理因果、可视化**的真实故事；一个日常类比 |
| 2. Script | 55–70s，约 3.7 词/秒 | 8 段公式（见 §3）；画面已 obvious 的不写 |
| 3. Voice | `voice.wav` + `words.json` | 词级时间必须手修；所有镜头对齐 `words.json` |
| 4. Shot plan | `story.ts`：SHOTS/XFADE/FLASH_AT/CAMS/KICKS/DOF/FOREGROUND | 每个视觉反应比对应词早 0–3 帧 |
| 5. World | `lights.ts`/`shade.ts`/`build.ts`/`paint.ts`/`world.ts` | 相机视线剔除；天空/雾/河/太阳；每镜头冻结太阳 |
| 6. Characters | `toon.ts`/`cast.ts`/`cardshade.ts` | 2D billboard、豆头、stick limbs、plum 墨线、14 表情 |
| 7. Post | `Bridge.tsx`/`ink.ts`/`lensblur.ts`/`grade.ts` | ink → lens pre → lens main → bloom → NEUTRAL tone map → grade |
| 8. Sound | `timeline.py`/`sfx_gen.py`/`sfx.py`/`music.py`/`mix.py` | 先锁画面时间常数；事件表 → SFX + 原创 score + ducking |
| 9. Look checks | 静帧、side-by-side、Verifier 评分 | 每轮 1–3 图 + ≤200 词结论；按文件 owner 分 sandbox |
| 10. Final render | h264 crf16、2K、mux 音频 | `--scale 1.3333`；`-map 0:v:0 -map 1:a:0`；QA 脚本全帧检查 |
| 11. Deliver | final mp4 + notes | 交片前跑深度审计；不把「渲染退出 0」当完成 |

## 3. 脚本公式（20/20 参考片都符合）

- **时长/语速**：55–70s，3.5–4.1 词/秒（中位 3.7），词间停顿极少。
- **Hook**：第 1 句把悖论当事实说；10–16 词；无 setup、无 logo/intro/outro/CTA。
  - 例：*"Seventy-four soldiers knocked down an iron bridge just by walking across it."*
- **Setting**：1–2 句，现在时，具体时间/地点/普通人。
- **Escalation**：3–6 个 beat，每次更大；1–2 个夸张笑话；可有 in-character 对白。
- **Mystery beat**：一句 *"Wait, …?"* 或问题。
- **Pivot**：*"You see,"* → 真实机制 + 日常类比（秋千/身体/水管）。
- **Ironic payoff**：最后 1–2 句短句，反转；最后一个词收尾。
- **两种叙述**：第三人称故事模式 / "Imagine you're…" 第二人称。
- **句子**：中位约 13.5 词，口语、缩写、术语下一句解释；不要描述画面已经展示的东西。
- **事实**：每个事实带来源；笑话必须是研究过的真实事实，不是编造。

## 4. 镜头表数据模型

`story.ts` 是镜头/相机/光照的唯一排期：

| 字段 | 含义 |
| --- | --- |
| `SHOTS` | `{id, a, b, light: day|golden, crowd, tau}`；帧区间 + 故事时间 |
| `XFADE` | 地点/时间变化的 6–8 帧 crossfade |
| `FLASH_AT` | hook 后的 4 帧白闪 |
| `CAMS` | 每镜头关键帧 `{f, dur?, cut?, s: f => {pos, look, fov, roll}}` |
| `KICKS` | 冲击帧的 flip-shake，7 帧衰减 |
| `DOF` / `dofAt` | 每 beat 的镜头模糊强度 |
| `FOREGROUND` | 近景框景道具，约 1/3 镜头 |
| `words.json` | 词级时间；视觉反应对齐到词前 0–3 帧 |

相机语法（测量自参考片）：

- 硬切只用于大跳变；其余是 **smootherstep 滑翔 18–40 帧**，720p 峰值 ≤25px/帧。
- 每个 hold 都有 **0.15–0.35%/帧** 的缓慢 push-in；punch 词约 0.6%/帧。
- 冲击 shake 每帧翻转符号，7 帧衰减；roll 4–4.6°；无手持漂移。
- 连续运镜替代转场：跟随物体、whip pan + 运动模糊、穿窗/舷窗、6–8 帧 dissolve。

## 5. 视觉语法与 look 数值

**核心**：2D 扁平卡通角色（billboard）站在 3D 手绘彩色世界里；世界有黑墨描边、
饱和天空、景深、暖 key + 蓝紫阴影；角色接受场景光/影，不是自发光贴片。

| 项 | 数值/规则 |
| --- | --- |
| 画幅 | 1080×1920，30fps；最终 1440×2560 |
| 世界墨线 | 约 3px@1080，近黑 #0b0a0c，随距离近常数；轮廓/深度跳变/法线折痕，不做墙/地接缝与地平线 |
| 角色墨线 | 深 plum #201628–#2f1d28，底/阴影侧更粗；角色卡不被世界 ink 描边（`NOINK` 层） |
| 天空（日） | top #3e7fd2 → horizon #b8d0ec，fog=horizon，25→300m，uSat 1.08，60m 后约 15% 蓝雾 |
| 日光照 | az 75 / el 48；lit [1.58,1.5,1.33]；shade [.30,.29,.36]；lift [.05,.06,.11]（冷色只在阴影） |
| 黄金光 | az 6 / el 7 逆光；key #FFB36B×1.5；紫蓝阴影（立面≈#444380）；sky #ffc47c→#8a6f8a；50m 后桃色雾；太阳盘 #ffcf9e + bloom |
| 建筑 albedo | 砖/奶油/赭/赤陶，带 plinth/cornice/sill/hood/step/chimney；高 7/8.4/9.8m；比 storybook 降饱和 35%；不要柠檬黄/薰衣草紫 |
| DOF | 1080 下 cInf：hook/河 CU 15–16，close-up 12–14，MS 10–12，park 7，golden sway 5，wide/aerial 0；对焦前排眼睛 |
| 后期顺序 | ink → lens pre → lens main → bloom（thr 1.0, int .5, 6 levels, radius .6）→ NEUTRAL tone map → grade；MSAA 4；grain 关闭 |
| 角色 | 豆头 h/w .94，眼距 .26W，无腮红/高光，14 表情；成人 3.5 头身，腿 1.4HH；步 bob 5%，lean 1–7°，步幅 0.8m；眨眼 0.5–2.3s |
| 色彩统计 | 日间 luma 中位 .57，非 ink p5 .23，lit chroma p90 ≈55；天空 top #5e93d9，horizon 亮 1.28× |
| 深度 | fog=horizon，日 25→420m，golden 20→360m；bloom 只给 HDR emissive，threshold 1.0 |

**可读性坑**（作者 verifier 实测）：
- 秋千画成一根绳消失在孩子后面 → 读成上吊；必须两绳 + 宽板 + 孩子在内。
- 近镜头 2m 内的道具会变成画面边缘的巨大截断色块；相机移动后要重查。
- 前景灌木被边缘切断 → 读成「绿球」；要么可识别，要么删。
- 旗帜颜色/图案可能误读为某国国旗；用时代正确的旗帜。
- 侧光下的手绘招牌会变灰蓝不可读；招牌面用 unlit 材质。
- 金色轮廓光用 offset 外复制 → 每个帽子变画框；只用 inner rim。
- 栏杆在胸口高度穿过角色 → 镜头抬高到约 2.5m，让栏杆过腿不过躯干。
- 静止 hold ≥12 帧在 QA 里读成 freeze；每个 hold 必须有 creep push-in。

## 6. 声音与混音

- 事件表 → 合成 SFX + 原创进行曲 score；输出 `mix.wav`（48kHz，精确长度）、
  stems、`cues.md`。
- 标准混音：**music +3 dB、SFX −6 dB、voice 不变**；整体约 −14 LUFS、LRA 2.4；
  ducking 让音乐/SFX 在语音下低 5–10dB。
- **先锁画面时间常数再合成声音**；之后任何 timing 改动都要重跑声音。
- 声音是原创合成，不扒现成音乐/音效；参考片只做风格研究。

## 7. 渲染与 QA

### 7.1 Remotion `renderMedia()` 事实（只参考）

- Node/Bun 服务端 API，不在浏览器；先 `selectComposition()` 再 `renderMedia()`。
- 必需：`serveUrl`、`composition`、`codec`；`outputLocation` 省略则返回内存 buffer。
- `inputProps` 必须同时传给 `selectComposition`；`scale` 缩放输出。
- `imageFormat`：`jpeg` 默认/最快，`png` 透明，`none` 仅音频；`jpegQuality` 默认 80。
- `concurrency`：默认 CPU 线程一半、上限 8；`frameRange` 支持单帧/多段。
- `muted` 优先于 `enforceAudioTrack`；`enforceAudioTrack` 默认 false，拼接时设 true。
- 浏览器：`browserExecutable`/`puppeteerInstance`；`chromeMode` 默认 `headless-shell`。
- 编码：`crf` 与硬件加速不能同用；`x264Preset` 默认 medium；`audioBitrate` 默认 320k；
  `sampleRate` 默认 48000；`hardwareAcceleration` 默认 disable；`colorSpace` 默认 default。
- **无跨运行确定性保证**；`ffmpegOverride` 被明确不推荐（命令随版本变）。
- Remotion 会写一条静音音轨；用 `-map 0:v:0 -map 1:a:0` 与真实音频 mux。

### 7.2 Three.js Renderer 事实（只参考）

- 文档是 backend-agnostic `Renderer`（WebGLRenderer/WebGPURenderer）；
  `alpha` 默认 true、`depth` true、`stencil` false、`antialias` false、`samples` 0。
- `outputColorSpace` 默认 `SRGBColorSpace`；`toneMapping` 默认 `NoToneMapping`；
  `toneMappingExposure` 默认 1。
- `autoClear` 默认 true；离线逐帧建议显式 clear，避免残留状态。
- `setPixelRatio`/`setSize` 固定；不要依赖 `devicePixelRatio`。
- `setAnimationLoop` 内 `render()` 保证已初始化；按需渲染必须先 `init()`。
- `compileAsync()` 预编译材质，避免首帧 shader stutter。
- RenderTarget + `readRenderTargetPixelsAsync()` 可固定分辨率读回帧；
  MSAA 在 tone mapping/color conversion/fullscreen pass 时可能被静默降为 0。
- `dispose()` 释放；WebGL context loss 用 `domElement` 的 `webglcontextlost`，
  WebGPU 用 `onDeviceLost`。
- 透明排序是启发式；固定内容可考虑固定 sort/`setTransparentSort(null)`。

### 7.3 作者的 QA 脚本

`templates/scripts/short_qa.py` 对成片做全帧检查：

- ffprobe：分辨率、fps、帧数、时长、音频 codec/采样率/声道。
- ffmpeg `ebur128`：LUFS/LRA/peak；`silencedetect`：静音段。
- 180×320 缩帧 → 每帧 luma/sat/p2/p98；黑帧（mean<0.04）、非计划白帧
  （mean>0.93）、冻结段（diff<0.02 连续 ≥12 帧）、pops（diff>3×局部中位+1）。
- 每镜头 luma mean/std/p2/p98/sat 中位数；每 2s 一张 10×6 接触表（帧号烧入）。
- planned flash/xfade/shot 边界从 `shots.json` 排除，避免误报。

**Look-match loop**：先测量参考（7 个主题报告，写数字不写形容词）→ 每个 owner
一个 sandbox（cam/world/mat/char/post）→ 只改自己文件 → `bridge_merge.py` 合并 →
`tsc --noEmit` → 重新同步 sandbox → fresh verifier 看 side-by-side，按 8 个维度
打分 + 编号 fix list → 按文件 owner 继续修。参考片只做风格研究，不复制内容。

## 8. 只借什么 / 不借什么

| 借 | 不借 |
| --- | --- |
| 8 段脚本公式、词级时间、镜头表 schema | Remotion / `@remotion/three` / React / Node / Chromium 运行时 |
| 相机语法（滑翔/hold creep/flip shake/roll/foreground） | 1.3GB `public/` 资产与 Remotion bundle 流程 |
| look 数值（墨线/光/albedo/DOF/post/角色比例） | 作者的参考视频、参考帧、角色、脚本、配音、音乐 |
| QA 逻辑（黑/白/冻结/pops/响度/接触表） | 作者的参考频道名/品牌/具体镜头 |
| look-match loop（报告 → sandbox → merge → fresh verifier） | 「英语 only / 无字幕 / 男声」等作者的个人规则（按项目定） |
| 「故事/角色/声音必须是自己的」版权纪律 | 把参考片当素材上传/发布/再分发 |

**3D 例外**：three.js 本身已是我们直接引入的 3D 栈；但本仓库的 Remotion 集成
**不在**该例外内。`toon_3d` 候选风格只用 three-live + 我们自己的渲染/导出。

## 9. 映射到我们的视频工作台

### 9.1 候选风格 `toon_3d`

- 定位：55–70s 竖屏动画短剧，2D 扁平角色 + 3D 手绘世界，墨线/景深/滑翔相机。
- 与现有风格的区别：
  - `silly_skit`：2D cutout、沙雕夸张、pixelfx 战斗特效；
  - `line_toon`：美式硬线分格；
  - `ink_line`：细墨线/暖纸/无脸小人；
  - `toon_3d`：2D billboard 角色 **站在真 3D 世界**里，世界有 PBR/手绘纹理/雾/景深。
- 状态：**调研候选，待裁决**；不改变当前“三风格”定稿口径。

### 9.2 `screenplay.json` 增量

```jsonc
{
  "style": "toon_3d",
  "fps": 30,
  "stage": { "w": 1080, "h": 1920 },
  "words": [{ "w": "Seventy-four", "start": 0, "end": 0.42 }],
  "shots": [{
    "id": 1, "a": 0, "b": 130,
    "light": "day", "crowd": "march", "tau": "29.5+t",
    "cam": [{ "f": 0, "pos": [7.5, 8.6, -13], "look": [0, 8.4, 5], "fov": 44, "roll": 0 }],
    "dof": 15,
    "foreground": ["hat"],
    "kicks": [{ "f": 130, "amp": 2.2 }]
  }],
  "xfade": { "9": 6, "11": 8 },
  "flashAt": 130,
  "audio": { "voice": "voice.wav", "music": "score.wav", "sfx": "cues.json",
             "loudnessLufs": -14, "musicDb": 3, "sfxDb": -6 }
}
```

- `words.json` 是时间主轴；视觉反应对齐到词前 0–3 帧。
- `light` 是风格包的光照预设（day/golden/night）；`tau` 是故事时间，不是 wall clock。
- `cam` 关键帧只描述 pos/look/fov/roll；切/滑翔/hold creep 由编译器按规则生成。
- `dof` 是 cInf px；`foreground` 是框景道具；`kicks` 是冲击 shake。

### 9.3 实现路径（未施工）

| 层 | 我们的做法 |
| --- | --- |
| 3D 世界 | three-live 执行 three.js 场景；手绘 Canvas2D 纹理 + PBR/Lambert 材质；雾/天空/河 |
| 角色 | Canvas2D 画到纹理 → billboard plane；`NOINK` 层；接受场景光/影；固定 600×1000 设计画布，soles y=975 |
| 后期 | three.js EffectComposer/自定义 pass：ink（法线+深度）→ lens pre/main → bloom → neutral tone map → grade；MSAA 4；分辨率参数按输出高度缩放 |
| 时间 | 30fps 整数帧；`stateAt(frame)`；`words.json` 对齐；seek=reset+replay；无 Remotion |
| 声音 | 事件表 → 我们自己的 Web Audio/离线合成；ducking；-14 LUFS；stems/cues |
| QA | 移植 `short_qa.py` 逻辑到 Dart/JS 开发脚本：黑/白/冻结/pops/响度/接触表；最终 2K 逐帧检查 |
| 导出 | 现有 readPixels→ffmpeg 路线；h264 crf16；mux 音频；帧级可复现，码流级不承诺 |

**不做**：不在产品里跑 Remotion/React/Node/Chromium；不复制参考帧/角色/脚本；
不引入 1.3GB 资产；不把作者的「无字幕/英语/男声」当我们的默认规则。

## 10. 未验证 / 待补

- 未安装/运行该仓库；没有实测它的渲染质量、性能、2K 导出、音频合成。
- 未验证 three-live 能否承载该后处理链（ink 法线/深度 pass、lens blur、bloom、
  EffectComposer）在 WKWebView/WebView2 的 1080×1920 30fps 预算；需要 spike。
- 未验证 billboard 角色 + 场景光/影在 three-live 的材质/阴影路径；可能需要
  自定义 shader 或 depth material。
- 未验证 `short_qa.py` 逻辑移植到 Dart/JS 的数值阈值（黑/白/冻结/pops）在
  我们的编码器/色彩管理下是否一致。
- 未决定 `toon_3d` 是否进入正式风格包；本轮只登记候选。
- 未核验 Remotion 许可的具体商用条款；本文只按「不引入」处理。
- 未核验参考帧/视频的版权边界；我们不会复制或分发它们。

## 11. 来源

- 仓库：<https://github.com/mromidev/claude-animated-shorts>
- `README.md`、`SKILL.md`、`references/STYLE_BIBLE.md`、`references/reports/CONTEXT.md`、
  `templates/scripts/short_qa.py`、`templates/bridge/story.ts`
- Remotion `renderMedia()`：<https://www.remotion.dev/docs/renderer/render-media>
- Three.js Renderer：<https://threejs.org/docs/pages/Renderer.html>
- GitHub metadata（stars/forks/license/updated，2026-11-24 核验）
